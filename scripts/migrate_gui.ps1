# Claude Code Migration Tool - standalone GUI for the project-backup skill.
# No Claude Code session required. Wraps backup.sh / history.sh (unchanged)
# via Git Bash. See SKILL.md's "One-click migration" section for the
# equivalent AI-driven flow this mirrors phase-for-phase.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptsDir  = $PSScriptRoot
$BackupSh    = Join-Path $ScriptsDir 'backup.sh'
$HistorySh   = Join-Path $ScriptsDir 'history.sh'
$VendorBatchPy = Join-Path $ScriptsDir 'vendor\claude-code-export-import\batch.py'
$SettingsDir = Join-Path $env:LOCALAPPDATA 'ClaudeProjectBackupGUI'
$SettingsFile = Join-Path $SettingsDir 'settings.json'

# ---------------------------------------------------------------------------
# Helpers (also re-injected into the background runspace as source text -
# see Get-FunctionDefinitionsScript / Start-MigrationRun below - so keep
# these self-contained: no closures over script-scope variables except the
# constants above, which are captured by value when the text is re-parsed).
# ---------------------------------------------------------------------------

function Find-GitExe {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-BashExe {
    # Deliberately not `Get-Command bash` - Windows ships a WSL launcher
    # stub at C:\Windows\System32\bash.exe that can shadow real Git Bash
    # depending on PATH order. Resolve via git.exe's own install location.
    $gitExe = Find-GitExe
    if ($gitExe) {
        $gitRoot = Split-Path (Split-Path $gitExe)
        $candidate = Join-Path $gitRoot 'bin\bash.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    $fallbacks = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LocalAppData\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $fallbacks) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-GhExe {
    $cmd = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallbacks = @(
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe"
    )
    foreach ($p in $fallbacks) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-PythonExe {
    # Optional - only needed for the "full desktop-app fidelity" experimental
    # phases. On a fresh Windows install, `python.exe`/`python3.exe` resolve
    # to an App Execution Alias stub under WindowsApps that just opens the
    # Microsoft Store (exit code 49, no version string) rather than failing
    # to resolve at all - Get-Command alone would report a false positive,
    # so actually run --version and check the output.
    foreach ($name in @('python.exe', 'python3.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            $verOutput = & $cmd.Source --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $verOutput -match 'Python \d') {
                return $cmd.Source
            }
        } catch { }
    }
    return $null
}

function ConvertTo-ArgString {
    # .NET Framework's ProcessStartInfo has no ArgumentList array property
    # (that's a .NET Core addition) - build one properly-quoted string.
    param([string[]]$ArgList)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgList) {
        if ($a -match '[\s"]') {
            $escaped = $a -replace '"', '\"'
            $parts.Add('"' + $escaped + '"')
        } else {
            $parts.Add($a)
        }
    }
    return ($parts -join ' ')
}

function Invoke-StreamedProcess {
    # Event-driven redirected-output reading, not ReadToEnd()-after-
    # WaitForExit() - the latter deadlocks once output exceeds the OS pipe
    # buffer, a real risk with dozens-of-repos clone logs.
    param(
        [string]$FilePath,
        [string]$Arguments,
        [hashtable]$EnvVars,
        [scriptblock]$OnLine
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    if ($EnvVars) {
        foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $queue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]

    $outAction = { if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } }
    $errAction = { if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue('[stderr] ' + $EventArgs.Data) } }

    $subOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outAction -MessageData $queue
    $subErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $errAction -MessageData $queue

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    while ((-not $proc.HasExited) -or (-not $queue.IsEmpty)) {
        $line = $null
        while ($queue.TryDequeue([ref]$line)) {
            & $OnLine $line
        }
        Start-Sleep -Milliseconds 50
    }
    $proc.WaitForExit()

    Unregister-Event -SourceIdentifier $subOut.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $subErr.Name -ErrorAction SilentlyContinue

    return $proc.ExitCode
}

function Get-Settings {
    if (Test-Path $SettingsFile) {
        try { return (Get-Content $SettingsFile -Raw | ConvertFrom-Json) } catch { }
    }
    return [PSCustomObject]@{ LastRoot = ''; LastArchive = ''; LastMode = 'restore' }
}

function Save-Settings {
    param($Obj)
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
    $Obj | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
}

function Find-HistoryArchive {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        $env:USERPROFILE
    )
    $found = @()
    foreach ($dir in $candidates) {
        if (Test-Path $dir) {
            $found += Get-ChildItem -Path $dir -Filter 'claude-history-export-*.tar.gz' -File -ErrorAction SilentlyContinue
        }
    }
    return $found
}

# ---------------------------------------------------------------------------
# Form construction
# ---------------------------------------------------------------------------

$settings = Get-Settings

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code Migration Tool'
$form.Size = New-Object System.Drawing.Size(780, 860)
$form.MinimumSize = New-Object System.Drawing.Size(700, 600)
$form.StartPosition = 'CenterScreen'

$ctl = @{}

# --- Header panel ---
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = 'Top'
$pnlHeader.Height = 190
$pnlHeader.Padding = New-Object System.Windows.Forms.Padding(10)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Claude Code Migration Tool'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(10, 5)

$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'What do you want to do?'
$grpMode.Location = New-Object System.Drawing.Point(10, 35)
$grpMode.Size = New-Object System.Drawing.Size(740, 55)

$rbBackup = New-Object System.Windows.Forms.RadioButton
$rbBackup.Text = 'Back up this machine (old machine)'
$rbBackup.Location = New-Object System.Drawing.Point(15, 22)
$rbBackup.AutoSize = $true

$rbRestore = New-Object System.Windows.Forms.RadioButton
$rbRestore.Text = 'Restore onto this machine (new machine)'
$rbRestore.Location = New-Object System.Drawing.Point(320, 22)
$rbRestore.AutoSize = $true
$rbRestore.Checked = $true
if ($settings.LastMode -eq 'backup') { $rbBackup.Checked = $true; $rbRestore.Checked = $false }

$grpMode.Controls.AddRange(@($rbBackup, $rbRestore))

$lblRoot = New-Object System.Windows.Forms.Label
$lblRoot.Text = 'Projects root:'
$lblRoot.Location = New-Object System.Drawing.Point(10, 100)
$lblRoot.AutoSize = $true

$txtRoot = New-Object System.Windows.Forms.TextBox
$txtRoot.Location = New-Object System.Drawing.Point(110, 97)
$txtRoot.Size = New-Object System.Drawing.Size(520, 23)
if ($settings.LastRoot) { $txtRoot.Text = $settings.LastRoot }

$btnBrowseRoot = New-Object System.Windows.Forms.Button
$btnBrowseRoot.Text = 'Browse...'
$btnBrowseRoot.Location = New-Object System.Drawing.Point(640, 96)
$btnBrowseRoot.Size = New-Object System.Drawing.Size(100, 25)
$btnBrowseRoot.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = 'Select your projects folder'
    if ($txtRoot.Text -and (Test-Path $txtRoot.Text)) { $fbd.SelectedPath = $txtRoot.Text }
    if ($fbd.ShowDialog() -eq 'OK') { $txtRoot.Text = $fbd.SelectedPath }
})

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = [char]0x25B6 + ' Start'
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnStart.Location = New-Object System.Drawing.Point(10, 135)
$btnStart.Size = New-Object System.Drawing.Size(740, 40)

$pnlHeader.Controls.AddRange(@($lblTitle, $grpMode, $lblRoot, $txtRoot, $btnBrowseRoot, $btnStart))

# --- Log panel (bottom) ---
$pnlLog = New-Object System.Windows.Forms.Panel
$pnlLog.Dock = 'Bottom'
$pnlLog.Height = 210
$pnlLog.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 10)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'Log:'
$lblLog.Dock = 'Top'
$lblLog.Height = 18

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'
$rtbLog.ReadOnly = $true
$rtbLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$rtbLog.WordWrap = $false
$rtbLog.ScrollBars = 'Both'

$pnlLog.Controls.Add($rtbLog)
$pnlLog.Controls.Add($lblLog)

# --- Dynamic middle panel ---
$pnlDynamic = New-Object System.Windows.Forms.Panel
$pnlDynamic.Dock = 'Fill'
$pnlDynamic.AutoScroll = $true
$pnlDynamic.Padding = New-Object System.Windows.Forms.Padding(10)

function New-PhaseGroup {
    param([string]$Title, [int]$Height)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Title
    $g.Width = 720
    $g.Height = $Height
    $g.Visible = $false
    $g.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    return $g
}

function New-PhaseListView {
    param($Parent)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.CheckBoxes = $true
    $lv.FullRowSelect = $true
    $lv.Location = New-Object System.Drawing.Point(10, 22)
    $lv.Size = New-Object System.Drawing.Size(695, ($Parent.Height - 70))
    [void]$lv.Columns.Add('Name', 260)
    [void]$lv.Columns.Add('Status', 140)
    [void]$lv.Columns.Add('Detail', 280)
    $Parent.Controls.Add($lv)
    return $lv
}

# grpPrereqs
$grpPrereqs = New-PhaseGroup -Title 'Checking prerequisites' -Height 130
$lvPrereqs = New-Object System.Windows.Forms.ListView
$lvPrereqs.View = 'Details'
$lvPrereqs.FullRowSelect = $true
$lvPrereqs.Location = New-Object System.Drawing.Point(10, 22)
$lvPrereqs.Size = New-Object System.Drawing.Size(695, 95)
[void]$lvPrereqs.Columns.Add('Check', 220)
[void]$lvPrereqs.Columns.Add('Result', 470)
$grpPrereqs.Controls.Add($lvPrereqs)

# grpAuth
$grpAuth = New-PhaseGroup -Title 'GitHub sign-in' -Height 100
$lblAuthCode = New-Object System.Windows.Forms.Label
$lblAuthCode.Location = New-Object System.Drawing.Point(15, 25)
$lblAuthCode.AutoSize = $true
$lblAuthCode.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold)
$lnkAuth = New-Object System.Windows.Forms.LinkLabel
$lnkAuth.Location = New-Object System.Drawing.Point(15, 55)
$lnkAuth.AutoSize = $true
$lnkAuth.Text = 'https://github.com/login/device'
$lnkAuth.Add_LinkClicked({ Start-Process 'https://github.com/login/device' })
$grpAuth.Controls.AddRange(@($lblAuthCode, $lnkAuth))

# grpArchive (restore mode)
$grpArchive = New-PhaseGroup -Title 'History archive' -Height 70
$lblArchive = New-Object System.Windows.Forms.Label
$lblArchive.Location = New-Object System.Drawing.Point(10, 25)
$lblArchive.AutoSize = $true
$txtArchive = New-Object System.Windows.Forms.TextBox
$txtArchive.Location = New-Object System.Drawing.Point(10, 22)
$txtArchive.Size = New-Object System.Drawing.Size(560, 23)
$txtArchive.Visible = $false
$btnBrowseArchive = New-Object System.Windows.Forms.Button
$btnBrowseArchive.Text = 'Browse...'
$btnBrowseArchive.Location = New-Object System.Drawing.Point(580, 21)
$btnBrowseArchive.Size = New-Object System.Drawing.Size(100, 25)
$btnBrowseArchive.Visible = $false
$grpArchive.Controls.AddRange(@($lblArchive, $txtArchive, $btnBrowseArchive))

# grpLocalProjects (backup mode)
$grpLocalProjects = New-PhaseGroup -Title 'Projects to back up' -Height 260
$lvLocal = New-PhaseListView -Parent $grpLocalProjects
$btnLocalGo = New-Object System.Windows.Forms.Button
$btnLocalGo.Text = 'Back Up Selected ' + [char]0x2192
$btnLocalGo.Location = New-Object System.Drawing.Point(10, ($grpLocalProjects.Height - 35))
$grpLocalProjects.Controls.Add($btnLocalGo)

# grpRemoteProjects (restore mode)
$grpRemoteProjects = New-PhaseGroup -Title 'Projects to sync down' -Height 260
$lvRemote = New-PhaseListView -Parent $grpRemoteProjects
$btnRemoteGo = New-Object System.Windows.Forms.Button
$btnRemoteGo.Text = 'Sync Selected ' + [char]0x2192
$btnRemoteGo.Location = New-Object System.Drawing.Point(10, ($grpRemoteProjects.Height - 35))
$grpRemoteProjects.Controls.Add($btnRemoteGo)

# grpExportItems (backup mode)
$grpExportItems = New-PhaseGroup -Title 'History & config to export' -Height 290
$lvExport = New-PhaseListView -Parent $grpExportItems
$lvExport.Size = New-Object System.Drawing.Size(695, ($grpExportItems.Height - 100))
$chkFidelityExport = New-Object System.Windows.Forms.CheckBox
$chkFidelityExport.Text = 'Also capture full desktop-app fidelity (experimental, third-party - may not work on this app build)'
$chkFidelityExport.AutoSize = $true
$chkFidelityExport.Location = New-Object System.Drawing.Point(10, ($grpExportItems.Height - 60))
$btnExportGo = New-Object System.Windows.Forms.Button
$btnExportGo.Text = 'Export Selected ' + [char]0x2192
$btnExportGo.Location = New-Object System.Drawing.Point(10, ($grpExportItems.Height - 35))
$grpExportItems.Controls.AddRange(@($chkFidelityExport, $btnExportGo))

# grpHistoryItems (restore mode)
$grpHistoryItems = New-PhaseGroup -Title 'History & config to restore' -Height 320
$lvHistory = New-PhaseListView -Parent $grpHistoryItems
$lvHistory.Size = New-Object System.Drawing.Size(695, ($grpHistoryItems.Height - 130))
$btnHistoryGo = New-Object System.Windows.Forms.Button
$btnHistoryGo.Text = 'Import Selected ' + [char]0x2192
$btnHistoryGo.Location = New-Object System.Drawing.Point(10, ($grpHistoryItems.Height - 35))
$grpHistoryItems.Controls.Add($btnHistoryGo)

# chkResume / chkFidelityImport (restore mode only - shown before Import)
$chkResume = New-Object System.Windows.Forms.CheckBox
$chkResume.Text = 'Show manual desktop-app resume instructions when done (this step cannot be automated)'
$chkResume.AutoSize = $true
$chkResume.Location = New-Object System.Drawing.Point(10, ($grpHistoryItems.Height - 90))

$chkFidelityImport = New-Object System.Windows.Forms.CheckBox
$chkFidelityImport.Text = 'Attempt full desktop-app fidelity restore (experimental, third-party - needs Python and the bundle from step 2 on the old machine)'
$chkFidelityImport.AutoSize = $true
$chkFidelityImport.Location = New-Object System.Drawing.Point(10, ($grpHistoryItems.Height - 65))

# grpResumeInstructions (restore mode)
$grpResumeInstructions = New-PhaseGroup -Title 'Making history resumable in the desktop app (manual)' -Height 300
$rtbResume = New-Object System.Windows.Forms.RichTextBox
$rtbResume.Location = New-Object System.Drawing.Point(10, 22)
$rtbResume.Size = New-Object System.Drawing.Size(695, 230)
$rtbResume.ReadOnly = $true
$rtbResume.Font = New-Object System.Drawing.Font('Consolas', 9)
$btnCopyResume = New-Object System.Windows.Forms.Button
$btnCopyResume.Text = 'Copy to clipboard'
$btnCopyResume.Location = New-Object System.Drawing.Point(10, 258)
$btnCopyResume.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($rtbResume.Text) })
$btnSaveResume = New-Object System.Windows.Forms.Button
$btnSaveResume.Text = 'Save as .txt...'
$btnSaveResume.Location = New-Object System.Drawing.Point(140, 258)
$btnSaveResume.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'Text file|*.txt'
    $sfd.FileName = 'resume-instructions.txt'
    if ($sfd.ShowDialog() -eq 'OK') { $rtbResume.Text | Set-Content -Path $sfd.FileName -Encoding UTF8 }
})
$grpResumeInstructions.Controls.AddRange(@($rtbResume, $btnCopyResume, $btnSaveResume))

$pnlDynamic.Controls.AddRange(@(
    $grpPrereqs, $grpAuth, $grpArchive,
    $grpLocalProjects, $grpExportItems,
    $grpRemoteProjects, $grpHistoryItems, $chkResume, $chkFidelityImport,
    $grpResumeInstructions
))

$form.Controls.Add($pnlDynamic)
$form.Controls.Add($pnlLog)
$form.Controls.Add($pnlHeader)

# Stack the dynamic groups top-to-bottom manually (Panel has no vertical
# FlowLayout with AutoScroll reliability across all these control types).
function Update-DynamicLayout {
    $y = 5
    foreach ($g in @($grpPrereqs, $grpAuth, $grpArchive, $grpLocalProjects, $grpExportItems,
                      $grpRemoteProjects, $grpHistoryItems, $chkResume, $chkFidelityImport, $grpResumeInstructions)) {
        if ($g.Visible) {
            $g.Location = New-Object System.Drawing.Point(5, $y)
            $y += $g.Height + 10
        }
    }
}

$ctl = @{
    form = $form; rtbLog = $rtbLog
    grpPrereqs = $grpPrereqs; lvPrereqs = $lvPrereqs
    grpAuth = $grpAuth; lblAuthCode = $lblAuthCode; lnkAuth = $lnkAuth
    grpArchive = $grpArchive; lblArchive = $lblArchive; txtArchive = $txtArchive; btnBrowseArchive = $btnBrowseArchive
    grpLocalProjects = $grpLocalProjects; lvLocal = $lvLocal; btnLocalGo = $btnLocalGo
    grpRemoteProjects = $grpRemoteProjects; lvRemote = $lvRemote; btnRemoteGo = $btnRemoteGo
    grpExportItems = $grpExportItems; lvExport = $lvExport; btnExportGo = $btnExportGo; chkFidelityExport = $chkFidelityExport
    grpHistoryItems = $grpHistoryItems; lvHistory = $lvHistory; btnHistoryGo = $btnHistoryGo
    chkResume = $chkResume; chkFidelityImport = $chkFidelityImport
    grpResumeInstructions = $grpResumeInstructions; rtbResume = $rtbResume
    btnStart = $btnStart; txtRoot = $txtRoot; rbBackup = $rbBackup; rbRestore = $rbRestore
}

# ---------------------------------------------------------------------------
# Cross-thread sync primitives for the two review checkpoints
# ---------------------------------------------------------------------------

$sync = [hashtable]::Synchronized(@{
    LocalCheckpoint   = New-Object System.Threading.ManualResetEvent($false)
    LocalSelected     = @()
    RemoteCheckpoint  = New-Object System.Threading.ManualResetEvent($false)
    RemoteSelected    = @()
    ExportCheckpoint  = New-Object System.Threading.ManualResetEvent($false)
    ExportSelected    = @()
    HistoryCheckpoint = New-Object System.Threading.ManualResetEvent($false)
    HistorySelected   = @()
})

$btnLocalGo.Add_Click({
    $names = @()
    foreach ($item in $lvLocal.CheckedItems) { $names += $item.Text }
    $sync.LocalSelected = $names
    $btnLocalGo.Enabled = $false
    $sync.LocalCheckpoint.Set()
})
$btnRemoteGo.Add_Click({
    $names = @()
    foreach ($item in $lvRemote.CheckedItems) { $names += $item.Text }
    $sync.RemoteSelected = $names
    $btnRemoteGo.Enabled = $false
    $sync.RemoteCheckpoint.Set()
})
$btnExportGo.Add_Click({
    $names = @()
    foreach ($item in $lvExport.CheckedItems) { $names += $item.Tag }
    $sync.ExportSelected = $names
    $btnExportGo.Enabled = $false
    $sync.ExportCheckpoint.Set()
})
$btnHistoryGo.Add_Click({
    $names = @()
    foreach ($item in $lvHistory.CheckedItems) { $names += $item.Tag }
    $sync.HistorySelected = $names
    $btnHistoryGo.Enabled = $false
    $sync.HistoryCheckpoint.Set()
})

# ---------------------------------------------------------------------------
# UI-touching operations - message-queue + UI-thread-timer pattern.
#
# Earlier versions of this script tried to have the background runspace
# call back into the UI via Form.Invoke(typed delegate). That turned out to
# be unreliable in practice (a delegate created from a scriptblock re-parsed
# inside a different runspace can end up bound to the wrong session state,
# so a control passed into it fails with "property 'Visible' cannot be
# found" even though the object is a real Control - confirmed by hand,
# repeatedly, not a guess). This version avoids Form.Invoke() entirely:
# the background runspace never touches a WinForms control, directly or
# via delegate. It only enqueues plain data (strings/bools/object refs, no
# scriptblocks) onto a thread-safe ConcurrentQueue. A System.Windows.Forms.
# Timer ticking on the UI thread drains that queue every ~80ms and applies
# the changes itself, natively on the UI thread - no cross-thread delegate
# marshaling anywhere in this path.
# ---------------------------------------------------------------------------

$UIQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 80
$uiTimer.Add_Tick({
    $cmd = $null
    while ($UIQueue.TryDequeue([ref]$cmd)) {
      try {
        switch ($cmd.Type) {
            'Log' {
                $rtbLog.AppendText($cmd.Text + "`r`n")
                $rtbLog.SelectionStart = $rtbLog.TextLength
                $rtbLog.ScrollToCaret()
            }
            'ShowPhase' {
                $cmd.Group.Visible = $true
                Update-DynamicLayout
            }
            'AddRow' {
                $item = New-Object System.Windows.Forms.ListViewItem($cmd.Name)
                [void]$item.SubItems.Add($cmd.Status)
                [void]$item.SubItems.Add($cmd.Detail)
                $item.Checked = $cmd.Checked
                $item.Tag = $cmd.Tag
                $cmd.Lv.Items.Add($item) | Out-Null
            }
            'PrereqResult' {
                $item = New-Object System.Windows.Forms.ListViewItem($cmd.Check)
                $mark = ''
                if ($cmd.Ok) { $mark = '[OK] ' + $cmd.Detail } else { $mark = '[MISSING] ' + $cmd.Detail }
                [void]$item.SubItems.Add($mark)
                if (-not $cmd.Ok) { $item.ForeColor = [System.Drawing.Color]::Red }
                $lvPrereqs.Items.Add($item) | Out-Null
            }
            'AuthCode' { $lblAuthCode.Text = 'Code: ' + $cmd.Code }
            'Enable' { $cmd.Control.Enabled = $true }
            'Error' { [System.Windows.Forms.MessageBox]::Show($cmd.Msg, 'Claude Code Migration Tool', 'OK', 'Error') | Out-Null }
            'Info' { [System.Windows.Forms.MessageBox]::Show($cmd.Msg, 'Claude Code Migration Tool', 'OK', 'Information') | Out-Null }
            'ArchiveInfo' { $txtArchive.Text = $cmd.Path; $lblArchive.Text = 'Using: ' + $cmd.Path }
            'ResumeText' { $rtbResume.Text = $cmd.Text }
            'PickArchive' {
                $ofd = New-Object System.Windows.Forms.OpenFileDialog
                $ofd.Filter = 'Claude history archive (*.tar.gz;*.tgz)|*.tar.gz;*.tgz|All files|*.*'
                $ofd.InitialDirectory = $cmd.InitialDir
                $picked = $null
                if ($ofd.ShowDialog() -eq 'OK') { $picked = $ofd.FileName }
                $cmd.Result.Value = $picked
                $cmd.Done.Set()
            }
            'GetResumeChecked' {
                $cmd.Result.Value = $chkResume.Checked
                $cmd.Done.Set()
            }
            'GetChecked' {
                $cmd.Result.Value = $cmd.Control.Checked
                $cmd.Done.Set()
            }
            'PickBundle' {
                $ofd = New-Object System.Windows.Forms.OpenFileDialog
                $ofd.Filter = 'Fidelity bundle (*.zip)|*.zip|All files|*.*'
                $ofd.InitialDirectory = $cmd.InitialDir
                $picked = $null
                if ($ofd.ShowDialog() -eq 'OK') { $picked = $ofd.FileName }
                $cmd.Result.Value = $picked
                $cmd.Done.Set()
            }
            'ConfirmCloseApp' {
                $procs = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
                if ($procs) {
                    $resp = [System.Windows.Forms.MessageBox]::Show(
                        "The Claude desktop app appears to be running. Full desktop-app fidelity restore needs it closed first, so it isn't writing to its data files while this runs.`n`nClose it now?",
                        'Claude Code Migration Tool', 'YesNo', 'Warning')
                    if ($resp -eq 'Yes') {
                        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Milliseconds 500
                        $cmd.Result.Value = $true
                    } else {
                        $cmd.Result.Value = $false
                    }
                } else {
                    $cmd.Result.Value = $true
                }
                $cmd.Done.Set()
            }
        }
      } catch {
        $rtbLog.AppendText("[GUI-BUG] UI queue command '" + $cmd.Type + "' failed: " + $_.Exception.Message + "`r`n")
        if ($cmd.Done) { $cmd.Done.Set() }
      }
    }
})
$uiTimer.Start()
$form.Add_FormClosed({ $uiTimer.Stop() })

# ---------------------------------------------------------------------------
# Orchestration logic. These functions get harvested via
# Get-FunctionDefinitionsScript and re-parsed as TEXT inside the background
# runspace (see the Start button handler below) - safe here because none of
# them touch a WinForms control directly; they only enqueue plain data onto
# $UIQueue (a thread-safe ConcurrentQueue, no PowerShell-runspace binding
# concerns at all) and, for the two places that need a synchronous answer
# back from the UI (file picker, checkbox state), block on a
# ManualResetEvent until the UI timer's tick handler fills in the result.
# ---------------------------------------------------------------------------

function UI-Log { param([string]$Text) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'Log'; Text = $Text }) }

function UI-ShowPhase { param($Group) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'ShowPhase'; Group = $Group }) }

function UI-AddRow {
    param($Lv, [string]$Name, [string]$Status, [string]$Detail, [bool]$Checked, [string]$Tag)
    $useTag = $Name
    if ($Tag) { $useTag = $Tag }
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'AddRow'; Lv = $Lv; Name = $Name; Status = $Status; Detail = $Detail; Checked = $Checked; Tag = $useTag })
}

function UI-PrereqResult {
    param([string]$Check, [bool]$Ok, [string]$Detail)
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'PrereqResult'; Check = $Check; Ok = $Ok; Detail = $Detail })
}

function UI-AuthCode { param([string]$Code) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'AuthCode'; Code = $Code }) }

function UI-Enable { param($Control) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'Enable'; Control = $Control }) }

function UI-Error { param([string]$Msg) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'Error'; Msg = $Msg }) }

function UI-Info { param([string]$Msg) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'Info'; Msg = $Msg }) }

function UI-ArchiveInfo { param([string]$Path) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'ArchiveInfo'; Path = $Path }) }

function UI-ResumeText { param([string]$Text) $UIQueue.Enqueue([PSCustomObject]@{ Type = 'ResumeText'; Text = $Text }) }

function UI-PickArchive {
    param([string]$InitialDir)
    $holder = [hashtable]::Synchronized(@{ Value = $null })
    $done = New-Object System.Threading.ManualResetEvent($false)
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'PickArchive'; InitialDir = $InitialDir; Result = $holder; Done = $done })
    $done.WaitOne() | Out-Null
    return $holder.Value
}

function UI-GetResumeChecked {
    $holder = [hashtable]::Synchronized(@{ Value = $false })
    $done = New-Object System.Threading.ManualResetEvent($false)
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'GetResumeChecked'; Result = $holder; Done = $done })
    $done.WaitOne() | Out-Null
    return $holder.Value
}

function UI-GetChecked {
    param($Control)
    $holder = [hashtable]::Synchronized(@{ Value = $false })
    $done = New-Object System.Threading.ManualResetEvent($false)
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'GetChecked'; Control = $Control; Result = $holder; Done = $done })
    $done.WaitOne() | Out-Null
    return $holder.Value
}

function UI-PickBundle {
    param([string]$InitialDir)
    $holder = [hashtable]::Synchronized(@{ Value = $null })
    $done = New-Object System.Threading.ManualResetEvent($false)
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'PickBundle'; InitialDir = $InitialDir; Result = $holder; Done = $done })
    $done.WaitOne() | Out-Null
    return $holder.Value
}

function UI-ConfirmCloseApp {
    $holder = [hashtable]::Synchronized(@{ Value = $false })
    $done = New-Object System.Threading.ManualResetEvent($false)
    $UIQueue.Enqueue([PSCustomObject]@{ Type = 'ConfirmCloseApp'; Result = $holder; Done = $done })
    $done.WaitOne() | Out-Null
    return $holder.Value
}

function Test-AllPrereqs {
    UI-ShowPhase $ctl.grpPrereqs
    UI-Log '=== Checking prerequisites ==='
    $gitExe = Find-GitExe
    $gitDetail = if ($gitExe) { $gitExe } else { 'not found - install from git-scm.com' }
    UI-PrereqResult -Check 'git' -Ok ([bool]$gitExe) -Detail $gitDetail

    $bashExe = Find-BashExe
    $bashDetail = if ($bashExe) { $bashExe } else { 'not found - Git for Windows includes this' }
    UI-PrereqResult -Check 'Git Bash' -Ok ([bool]$bashExe) -Detail $bashDetail

    $ghExe = Find-GhExe
    $ghDetail = if ($ghExe) { $ghExe } else { 'not found - install from cli.github.com' }
    UI-PrereqResult -Check 'gh (GitHub CLI)' -Ok ([bool]$ghExe) -Detail $ghDetail

    if (-not ($gitExe -and $bashExe -and $ghExe)) {
        UI-Log 'Missing required tools - cannot continue. See the list above.'
        UI-Error 'One or more required tools are missing. Check the Checking prerequisites list.'
        UI-Enable $ctl.btnStart
        return $null
    }

    git config --global core.longpaths true 2>&1 | Out-Null
    UI-Log 'Set git config --global core.longpaths true'

    $pyExe = Find-PythonExe
    $pyDetail = 'not found - optional, only needed for full desktop-app fidelity restore'
    if ($pyExe) { $pyDetail = $pyExe }
    UI-PrereqResult -Check 'Python (optional)' -Ok $true -Detail $pyDetail

    return @{ Git = $gitExe; Bash = $bashExe; Gh = $ghExe; Python = $pyExe }
}

function Ensure-GhAuth {
    param($Tools)
    $authCheck = & $Tools.Gh auth status 2>&1
    $ec = $LASTEXITCODE
    if ($ec -eq 0) {
        UI-PrereqResult -Check 'gh auth status' -Ok $true -Detail 'already signed in'
        return $true
    }
    UI-PrereqResult -Check 'gh auth status' -Ok $false -Detail 'not signed in - starting sign-in...'
    UI-ShowPhase $ctl.grpAuth
    UI-Log '=== GitHub sign-in ==='

    Invoke-StreamedProcess -FilePath $Tools.Gh -Arguments 'auth login --hostname github.com --git-protocol https --web' -OnLine {
        param($line)
        UI-Log $line
        if ($line -match '([A-Z0-9]{4}-[A-Z0-9]{4})') {
            UI-AuthCode $Matches[1]
        }
    } | Out-Null

    $authCheck2 = & $Tools.Gh auth status 2>&1
    if ($LASTEXITCODE -eq 0) {
        UI-Log 'Signed in to GitHub.'
        return $true
    } else {
        UI-Log 'GitHub sign-in did not complete.'
        UI-Error 'GitHub sign-in did not complete. Please re-run.'
        UI-Enable $ctl.btnStart
        return $false
    }
}

function Invoke-BackupSh {
    param($Bash, [string]$RootDir, [string]$Mode2, [string[]]$Names, [scriptblock]$OnLine)
    $argList = @($BackupSh, $Mode2) + $Names
    $argStr = ConvertTo-ArgString -ArgList $argList
    return Invoke-StreamedProcess -FilePath $Bash -Arguments $argStr -EnvVars @{ ROOT_DIR = $RootDir } -OnLine $OnLine
}

function Invoke-HistorySh {
    param($Bash, [string[]]$Args2, [scriptblock]$OnLine)
    $argList = @($HistorySh) + $Args2
    $argStr = ConvertTo-ArgString -ArgList $argList
    return Invoke-StreamedProcess -FilePath $Bash -Arguments $argStr -OnLine $OnLine
}

function Start-BackupMode {
    param($Tools, [string]$RootDir)

    $ok = Ensure-GhAuth -Tools $Tools
    if (-not $ok) { return }

    # Phase: list local projects
    UI-ShowPhase $ctl.grpLocalProjects
    UI-Log '=== Projects to back up ==='
    $lines = New-Object System.Collections.Generic.List[string]
    Invoke-BackupSh -Bash $Tools.Bash -RootDir $RootDir -Mode2 'list' -Names @() -OnLine { param($l) $lines.Add($l) } | Out-Null
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $p = $line -split "`t"
        $name = $p[0]; $status = $p[1]; $detail = $p[2]
        $preChecked = -not ($status -like 'skip-*')
        UI-AddRow $ctl.lvLocal $name $status $detail $preChecked ''
    }
    UI-Log 'Review the list, then click "Back Up Selected".'
    UI-Enable $ctl.btnLocalGo
    $sync.LocalCheckpoint.WaitOne() | Out-Null

    $selected = $sync.LocalSelected
    if ($selected.Count -gt 0) {
        UI-Log ('Backing up: ' + ($selected -join ', '))
        Invoke-BackupSh -Bash $Tools.Bash -RootDir $RootDir -Mode2 'init' -Names $selected -OnLine { param($l) UI-Log $l } | Out-Null
    } else {
        UI-Log 'Nothing selected to back up.'
    }

    # Phase: export items
    UI-ShowPhase $ctl.grpExportItems
    UI-Log '=== History & config to export ==='
    $expLines = New-Object System.Collections.Generic.List[string]
    Invoke-HistorySh -Bash $Tools.Bash -Args2 @('list-projects') -OnLine { param($l) $expLines.Add('P:' + $l) } | Out-Null
    Invoke-HistorySh -Bash $Tools.Bash -Args2 @('list-skills')   -OnLine { param($l) $expLines.Add('S:' + $l) } | Out-Null
    Invoke-HistorySh -Bash $Tools.Bash -Args2 @('list-config')   -OnLine { param($l) $expLines.Add('C:' + $l) } | Out-Null
    foreach ($raw in $expLines) {
        if ($raw.Length -lt 2) { continue }
        $kind = $raw.Substring(0, 1)
        $line = $raw.Substring(2)
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $p = $line -split "`t"
        $name = $p[0]; $size = $p[1]
        $tagPrefix = 'c:'
        if ($kind -eq 'P') { $tagPrefix = 'p:' } elseif ($kind -eq 'S') { $tagPrefix = 's:' }
        $preChecked = ($kind -eq 'C')
        UI-AddRow $ctl.lvExport $name $kind $size $preChecked ($tagPrefix + $name)
    }
    UI-Log 'Nothing is pre-checked for projects/skills (large & sensitive) - review, then click "Export Selected".'
    UI-Enable $ctl.btnExportGo
    $sync.ExportCheckpoint.WaitOne() | Out-Null

    $selectedExp = $sync.ExportSelected
    if ($selectedExp.Count -gt 0) {
        $outDir = Join-Path $env:USERPROFILE ('claude-history-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        UI-Log ('Exporting to: ' + $outDir + '.tar.gz')
        Invoke-HistorySh -Bash $Tools.Bash -Args2 (@('export', $outDir) + $selectedExp) -OnLine { param($l) UI-Log $l } | Out-Null
        UI-Info "Export complete: $outDir.tar.gz`n`nMove this file yourself (USB drive, a cloud folder you control) to the new machine."
    } else {
        UI-Log 'Nothing selected to export.'
    }

    # Phase: optional full desktop-app fidelity capture (experimental, third-party)
    $wantFidelity = UI-GetChecked $ctl.chkFidelityExport
    if ($wantFidelity) {
        if (-not $Tools.Python) {
            UI-Log '=== Full desktop-app fidelity skipped: Python not found ==='
        } else {
            UI-Log '=== Capturing full desktop-app fidelity (experimental) ==='
            $fidelityDir = Join-Path $env:TEMP ('ccei-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Path $fidelityDir -Force | Out-Null
            Invoke-StreamedProcess -FilePath $Tools.Python -Arguments (ConvertTo-ArgString -ArgList @($VendorBatchPy, 'export-all', '--out', $fidelityDir, '--with-config')) -OnLine { param($l) UI-Log $l } | Out-Null

            # Manifest: name -> absolute path on this machine, for every
            # project actually backed up above - lets restore mode later
            # build --path-map automatically instead of asking the user to
            # hand-write it.
            $manifest = @{}
            foreach ($name in $selected) {
                $manifest[$name] = (Join-Path $RootDir $name)
            }
            $manifestPath = Join-Path $fidelityDir 'project-paths.json'
            $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

            $bundlePath = Join-Path $env:USERPROFILE ('claude-fidelity-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
            Compress-Archive -Path (Join-Path $fidelityDir '*') -DestinationPath $bundlePath -Force
            Remove-Item -Path $fidelityDir -Recurse -Force -ErrorAction SilentlyContinue
            UI-Log ('Fidelity bundle written to: ' + $bundlePath)
            UI-Info "Full desktop-app fidelity bundle: $bundlePath`n`nThis is experimental and third-party - it may not work, depending on the destination machine's app version. Move this file to the new machine ALONGSIDE the history archive above; both are needed for the optional fidelity-restore step there."
        }
    }

    UI-Log '=== Done ==='
    UI-Enable $ctl.btnStart
}

function Start-RestoreMode {
    param($Tools, [string]$RootDir)

    $ok = Ensure-GhAuth -Tools $Tools
    if (-not $ok) { return }

    # Phase: archive discovery
    UI-ShowPhase $ctl.grpArchive
    UI-Log '=== Locating history archive ==='
    $found = Find-HistoryArchive
    $archivePath = $null
    if ($found.Count -eq 1) {
        $archivePath = $found[0].FullName
        UI-Log ('Found: ' + $archivePath)
    } else {
        $initDir = $env:USERPROFILE
        if ($found.Count -eq 0) {
            UI-Log 'No archive found automatically in Downloads/Documents/Desktop.'
        } else {
            UI-Log ('Found ' + $found.Count + ' possible archives - please pick one.')
            $initDir = $found[0].DirectoryName
        }
        $archivePath = UI-PickArchive $initDir
    }
    if (-not $archivePath) {
        UI-Log 'No archive selected - skipping history restore.'
    } else {
        UI-ArchiveInfo $archivePath
    }

    # Phase: config restore (automatic, import never overwrites)
    if ($archivePath) {
        UI-Log '=== Restoring config (settings, plugins) ==='
        Invoke-HistorySh -Bash $Tools.Bash -Args2 @('import', $archivePath, 'c:settings', 'c:plugins') -OnLine { param($l) UI-Log $l } | Out-Null
    }

    # Phase: remote projects
    UI-ShowPhase $ctl.grpRemoteProjects
    UI-Log '=== Projects to sync down ==='
    $lines = New-Object System.Collections.Generic.List[string]
    Invoke-BackupSh -Bash $Tools.Bash -RootDir $RootDir -Mode2 'list-remote' -Names @() -OnLine { param($l) $lines.Add($l) } | Out-Null
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $p = $line -split "`t"
        UI-AddRow $ctl.lvRemote $p[0] $p[1] $p[2] $true ''
    }
    UI-Log 'Review the list, then click "Sync Selected".'
    UI-Enable $ctl.btnRemoteGo
    $sync.RemoteCheckpoint.WaitOne() | Out-Null

    $selectedRemote = $sync.RemoteSelected
    if ($selectedRemote.Count -gt 0) {
        UI-Log ('Syncing: ' + ($selectedRemote -join ', '))
        Invoke-BackupSh -Bash $Tools.Bash -RootDir $RootDir -Mode2 'sync' -Names $selectedRemote -OnLine {
            param($l)
            UI-Log $l
            # backup.sh's sync already passes -c core.longpaths=true on
            # clone; a residual "Filename too long" failure here would mean
            # a stale partial clone from before that fix landed.
            if ($l -match 'Filename too long') {
                UI-Log '[note] a longpaths-related failure was reported above - re-run Sync for that project after this pass finishes, it should recover on retry'
            }
        } | Out-Null
    } else {
        UI-Log 'Nothing selected to sync.'
    }

    # Phase: history items
    if ($archivePath) {
        UI-ShowPhase $ctl.grpHistoryItems
        UI-Log '=== History & config to restore ==='
        $lines2 = New-Object System.Collections.Generic.List[string]
        Invoke-HistorySh -Bash $Tools.Bash -Args2 @('list-archive', $archivePath) -OnLine { param($l) $lines2.Add($l) } | Out-Null
        $currentKind = 'p'
        foreach ($line in $lines2) {
            if ($line -match '^==\s*projects\s*==$') { $currentKind = 'p'; continue }
            if ($line -match '^==\s*skills\s*==$') { $currentKind = 's'; continue }
            if ($line -match '^==\s*config\s*==$') { $currentKind = 'c'; continue }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $p = $line -split "`t"
            $name = $p[0]
            $size = ''
            if ($p.Count -gt 1) { $size = $p[1] }
            UI-AddRow $ctl.lvHistory $name $currentKind $size $true ($currentKind + ':' + $name)
        }
        UI-Log 'Everything is pre-checked - review, then click "Import Selected".'
        UI-Enable $ctl.btnHistoryGo
        $sync.HistoryCheckpoint.WaitOne() | Out-Null

        $selectedHist = $sync.HistorySelected
        if ($selectedHist.Count -gt 0) {
            UI-Log ('Importing: ' + ($selectedHist -join ', '))
            Invoke-HistorySh -Bash $Tools.Bash -Args2 (@('import', $archivePath) + $selectedHist) -OnLine { param($l) UI-Log $l } | Out-Null
        } else {
            UI-Log 'Nothing selected to import.'
        }
    }

    # Phase: optional full desktop-app fidelity restore (experimental, third-party)
    $wantFidelityImport = UI-GetChecked $ctl.chkFidelityImport
    if ($wantFidelityImport) {
        if (-not $Tools.Python) {
            UI-Log '=== Full desktop-app fidelity restore skipped: Python not found ==='
        } else {
            UI-Log '=== Full desktop-app fidelity restore (experimental) ==='
            $bundlePath = UI-PickBundle $env:USERPROFILE
            if (-not $bundlePath) {
                UI-Log 'No fidelity bundle selected - skipping.'
            } else {
                $extractDir = Join-Path $env:TEMP ('ccei-import-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
                Expand-Archive -Path $bundlePath -DestinationPath $extractDir -Force

                $manifestPath = Join-Path $extractDir 'project-paths.json'
                $pathMap = @{}
                if (Test-Path $manifestPath) {
                    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                    foreach ($prop in $manifest.PSObject.Properties) {
                        $oldPath = $prop.Value
                        $newPath = Join-Path $RootDir $prop.Name
                        $pathMap[$oldPath] = $newPath
                    }
                } else {
                    UI-Log 'Warning: no project-paths.json found in the bundle - path-map will be empty.'
                }
                $pathMapPath = Join-Path $extractDir 'path-map.json'
                $pathMap | ConvertTo-Json | Set-Content -Path $pathMapPath -Encoding UTF8

                $closeOk = UI-ConfirmCloseApp
                if (-not $closeOk) {
                    UI-Log 'Fidelity restore cancelled - the desktop app must be closed first.'
                } else {
                    $exitCode = Invoke-StreamedProcess -FilePath $Tools.Python -Arguments (ConvertTo-ArgString -ArgList @($VendorBatchPy, 'import-all', '--src', $extractDir, '--path-map', $pathMapPath, '--faithful', '--retention-days', '999999')) -OnLine { param($l) UI-Log $l }
                    if ($exitCode -eq 0) {
                        UI-Info "Fidelity restore finished. Reopen the Claude desktop app and check the sidebar.`n`nThis is experimental and unverified on this app build - if the sidebar still doesn't show the history, use the manual claude --resume steps below instead."
                    } else {
                        UI-Log ('Fidelity restore exited with code ' + $exitCode + ' - see the log above for the details.')
                        UI-Error 'Full desktop-app fidelity restore did not complete. See the log for details, and try the manual steps below instead.'
                    }
                }
                Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Phase: resume instructions (manual, never automated - see SKILL.md)
    $wantResume = UI-GetResumeChecked
    if ($wantResume -and $selectedRemote.Count -gt 0) {
        UI-ShowPhase $ctl.grpResumeInstructions
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('Known limitation (see anthropics/claude-code #90423, #81835, #89781):')
        [void]$sb.AppendLine('the Claude desktop app keeps its own session index, separate from the')
        [void]$sb.AppendLine('files this tool restores, so it will NOT show this history automatically.')
        [void]$sb.AppendLine('There is no command-line fix for this - do the following manually,')
        [void]$sb.AppendLine('once per project, with the desktop app running:')
        [void]$sb.AppendLine('')
        foreach ($name in $selectedRemote) {
            [void]$sb.AppendLine('--- ' + $name + ' ---')
            [void]$sb.AppendLine('1. Open a terminal in: ' + (Join-Path $RootDir $name))
            [void]$sb.AppendLine('2. Run: claude --resume')
            [void]$sb.AppendLine('3. Choose "Resume from summary" (or whichever prompt appears)')
            [void]$sb.AppendLine('4. Keep the desktop app open while doing this')
            [void]$sb.AppendLine('5. After closing the terminal, an auto-archive toast appears in the')
            [void]$sb.AppendLine('   app - click Undo on it to keep the session pinned')
            [void]$sb.AppendLine('')
        }
        [void]$sb.AppendLine('Note: sessions may land under "Other" in the sidebar grouping rather')
        [void]$sb.AppendLine('than their project group - this is a known upstream bug (#89781),')
        [void]$sb.AppendLine('not something this tool can fix.')
        UI-ResumeText $sb.ToString()
    }

    UI-Log '=== Done ==='
    UI-Enable $ctl.btnStart
}

# ---------------------------------------------------------------------------
# Runspace kickoff
# ---------------------------------------------------------------------------

function Get-FunctionDefinitionsScript {
    param([string[]]$Names)
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $Names) {
        $fn = Get-Item "function:$n" -ErrorAction SilentlyContinue
        if (-not $fn) { continue }
        [void]$sb.AppendLine("function $n {")
        [void]$sb.AppendLine($fn.Definition)
        [void]$sb.AppendLine('}')
    }
    return $sb.ToString()
}

$btnStart.Add_Click({
    $rootDir = $txtRoot.Text.Trim()
    if (-not $rootDir -or -not (Test-Path $rootDir)) {
        [System.Windows.Forms.MessageBox]::Show('Please choose a valid projects root folder.', 'Claude Code Migration Tool', 'OK', 'Warning') | Out-Null
        return
    }
    $mode = 'restore'
    if ($rbBackup.Checked) { $mode = 'backup' }

    $btnStart.Enabled = $false
    $rbBackup.Enabled = $false
    $rbRestore.Enabled = $false
    $txtRoot.Enabled = $false
    $btnBrowseRoot.Enabled = $false

    Save-Settings -Obj ([PSCustomObject]@{ LastRoot = $rootDir; LastArchive = ''; LastMode = $mode })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('UIQueue', $UIQueue)
    $rs.SessionStateProxy.SetVariable('ctl', $ctl)
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('BackupSh', $BackupSh)
    $rs.SessionStateProxy.SetVariable('HistorySh', $HistorySh)
    $rs.SessionStateProxy.SetVariable('VendorBatchPy', $VendorBatchPy)
    $rs.SessionStateProxy.SetVariable('RootDir', $rootDir)
    $rs.SessionStateProxy.SetVariable('Mode', $mode)

    $funcNames = @(
        'Find-GitExe', 'Find-BashExe', 'Find-GhExe', 'Find-PythonExe', 'ConvertTo-ArgString', 'Invoke-StreamedProcess',
        'Find-HistoryArchive', 'UI-Log', 'UI-ShowPhase', 'UI-AddRow', 'UI-PrereqResult', 'UI-AuthCode',
        'UI-Enable', 'UI-Error', 'UI-Info', 'UI-ArchiveInfo', 'UI-ResumeText', 'UI-PickArchive',
        'UI-GetResumeChecked', 'UI-GetChecked', 'UI-PickBundle', 'UI-ConfirmCloseApp',
        'Test-AllPrereqs', 'Ensure-GhAuth', 'Invoke-BackupSh', 'Invoke-HistorySh',
        'Start-BackupMode', 'Start-RestoreMode'
    )
    $funcScript = Get-FunctionDefinitionsScript -Names $funcNames

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($funcScript)
    [void]$ps.AddScript({
        try {
            $tools = Test-AllPrereqs
            if ($tools) {
                if ($Mode -eq 'backup') { Start-BackupMode -Tools $tools -RootDir $RootDir }
                else { Start-RestoreMode -Tools $tools -RootDir $RootDir }
            }
        } catch {
            $errMsg = $_.Exception.Message
            UI-Error "Unexpected error: $errMsg"
            UI-Enable $ctl.btnStart
        }
    })
    [void]$ps.BeginInvoke()
})

# ---------------------------------------------------------------------------

[void]$form.ShowDialog()
