# claude-project-backup

Back up your project folders to private GitHub repos, and migrate your
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) conversation
history, skills, and config to a new machine — either as a
[Claude Code skill](#as-a-claude-code-skill) (an AI agent drives the whole
flow for you, adapting to whatever goes wrong) or as a
[standalone Windows GUI](#as-a-standalone-gui-no-ai-required) (no AI session,
no terminal — double-click and go).

```
Claude Code Migration Tool
───────────────────────────────────────────
 ○ Back up this machine (old machine)
 ● Restore onto this machine (new machine)

 Projects root: [C:\Users\you\Documents  ]
          [ ▶ Start ]

 Checking prerequisites
   [OK] git      C:\Program Files\Git\cmd\git.exe
   [OK] gh       C:\Program Files\GitHub CLI\gh.exe
   [OK] Git Bash C:\Program Files\Git\bin\bash.exe

 Projects to sync down
   [✓] my-app         not-local   will clone from github.com/you/my-app
   [✓] notes           not-local   will clone from github.com/you/notes
   ...
          [ Sync Selected → ]
```

## Why this exists

Claude Code stores your work in two places that don't travel together:

1. **Your code** — wherever you keep it. Nothing special here; `git` already
   solves this.
2. **Your conversation history** — `~/.claude/projects/<encoded-path>/`,
   keyed by the *absolute path* of each project on *this* machine. A plain
   file copy or a new machine with a different username breaks this silently.

Anthropic doesn't ship a built-in way to move #2 between machines. This
project handles both, and also tackles the harder problem: the Claude
**desktop app**'s sidebar doesn't read from `~/.claude/projects/` at all — it
keeps its own separate index, so restoring your history correctly is not
the same as seeing it in the app. See [The desktop app problem](#the-desktop-app-problem-and-why-its-hard)
below — it's the most interesting (and most honestly-documented-as-unsolved)
part of this project.

## Two ways to use it

### As a standalone GUI (no AI required)

1. Clone or download this repo.
2. Double-click `scripts/Migrate.bat`.
3. Pick **Back up this machine** (on your old machine, before you switch) or
   **Restore onto this machine** (on your new machine).
4. Follow the on-screen phases. Two checkpoints along the way let you review
   and deselect anything before it touches your GitHub account or disk —
   nothing runs on "everything" without you seeing the list first.

Requires: [Git for Windows](https://git-scm.com/download/win) (ships `bash`),
the [GitHub CLI](https://cli.github.com/) (`gh`), and Windows PowerShell 5.1
(included in every Windows 10/11 install). No Python needed for the core
flow — Python is only checked for the optional experimental fidelity-restore
feature below.

### As a Claude Code skill

If you're already inside a Claude Code session:

```
/project-backup init | backup | sync | history export | history import <archive> | migrate
```

An AI agent drives the same flow interactively — it can adapt to problems
the GUI can't (a `gh` PATH issue, a Windows long-path clone failure, deciding
what to relay to you during GitHub sign-in) rather than just failing. See
[`SKILL.md`](SKILL.md) for the full behavior spec this repo's AI-driven mode
follows — it's written for an AI agent to read, but it's also the most
precise description of exactly what each command does.

To install: copy this repo into `~/.claude/skills/project-backup/` (or use
Claude Code's own skill-installer flow, if you have it, pointed at this
repo).

## What it does

### 1. Back up projects to GitHub (`backup.sh`)

- `list` — shows every folder directly under your projects root, its git
  status (new / uncommitted / up to date), and what will happen to it.
- `init <names>` — first-time backup: `git init` if needed, commits
  everything, creates a **private** GitHub repo per folder, pushes, tags it
  with the topic `claude-project-backup` (this is how `sync` finds your
  repos later without a manifest file — just your GitHub account).
- `backup <names>` — incremental: commits + pushes whatever changed.
- `list-remote` / `sync <names>` — on a new machine, lists every
  `claude-project-backup`-tagged repo under your account not already synced,
  then clones (or fast-forward-pulls) the ones you pick. Never overwrites
  local changes or force-pushes — a dirty or conflicting folder is skipped
  and reported, not clobbered.

### 2. Migrate conversation history, skills, and config (`history.sh`)

- `export <output-dir> <items>` — packages selected projects' history
  (`~/.claude/projects/<name>`), skills (`~/.claude/skills/<name>`), and/or
  config (`settings.json`, `plugins/`) into a `.tar.gz` you move yourself
  (USB drive, a cloud folder you control) — **never through GitHub**, since
  transcripts can contain anything you've ever typed or read into a session.
  Each project's per-session `~/.claude/file-history/<id>/` (Edit-tool file
  version history) and `~/.claude/session-env/<id>/` ride along automatically
  — without them, a restored session resumes fine but the desktop app's
  "Files" panel shows empty for it.
- `import <archive> <items>` — restores selected items on the new machine.
  Never overwrites an existing file — safe to run early, safe to re-run.
- Deliberately **never** touches `~/.claude/.credentials.json` (your login
  token — just sign in again on the new machine) or `~/.claude.json` (mixes
  account/telemetry state with per-project trust flags — not meaningful to
  copy wholesale).

### 3. One-click migration (`migrate` / `migrate_gui.ps1`)

Both interfaces sequence #1 and #2 into a single guided flow: check
prerequisites, sign in to GitHub if needed, find your history archive, pick
projects and history items (two review checkpoints — nothing pre-selected
blindly), then attempt to make history resumable in the desktop app (see
below).

## The desktop app problem, and why it's hard

Restoring `~/.claude/projects/` makes your history resumable from the
**terminal** (`claude --resume`) immediately. It does **not** make it appear
in the Claude **desktop app**'s sidebar. This is not a bug in this tool —
it's confirmed, unresolved, upstream behavior:

- The desktop app does not scan `~/.claude/projects/` at all. It reads from
  its own Electron/Chromium **IndexedDB** store, entirely separate from the
  CLI's transcript files. ([anthropics/claude-code#81835](https://github.com/anthropics/claude-code/issues/81835))
- Migrated history on Windows shows this exact symptom.
  ([#90423](https://github.com/anthropics/claude-code/issues/90423))
- Even sessions you do get to reappear tend to land under "Other" in the
  sidebar instead of their project's group — a separate, also-unresolved bug.
  ([#89781](https://github.com/anthropics/claude-code/issues/89781))

**What this project does about it, honestly:**

1. **The supported path**: a printed, step-by-step manual workaround — open
   a terminal in the project folder and run `claude --resume` (or `claude
   attach <id>` if it's a background session). This makes the conversation
   show up live in the desktop app for as long as that process keeps
   running — **not permanently**. Five separate tests (foreground open vs.
   closed, `--bg` running vs. `claude stop`-ed, then re-attached) all
   confirmed sidebar visibility tracks a live CLI process with no
   exception found: close the terminal and it disconnects; `claude stop` a
   background session and it disappears from the sidebar entirely; either
   way, `claude --resume`/`claude attach` brings it right back. Nothing
   about this — including "undo" on an archive-toast the app may show — makes
   it stick. Treat reconnecting as the normal way to use an old migrated
   conversation, not a one-time fix. Your transcript data itself is never
   at risk either way — only the app's sidebar convenience is ephemeral.
2. **An experimental, opt-in, third-party path**: `scripts/vendor/claude-code-export-import/`
   vendors [Dangelo123/claude-code-export-import](https://github.com/Dangelo123/claude-code-export-import)
   (MIT), which goes further — it copies the app's `local_*.json` records,
   `Local Storage` leveldb, *and* the `IndexedDB` store itself byte-for-byte
   (its values use Chromium's structured-clone format with length-prefixed
   strings, so it can't be safely rewritten in place — only copied whole).
   This needs Python and the desktop app closed during import, and is
   unchecked by default in the GUI. **It may not work** — that tool's own
   docs claim writing just the `local_*.json` records is enough, which
   directly contradicts what testing against a real Windows install found
   (the records folder didn't even exist). App-version drift between when
   either tool was tested and whatever version you're running is a real,
   acknowledged risk on both sides. If it doesn't work, fall back to path 1.

If you find a cleaner fix, please open an issue or PR — and consider
commenting on the upstream issues linked above, since this is fundamentally
an Anthropic-side gap, not something any of these community tools can fully
close.

## Repository layout

```
SKILL.md                                  AI-agent-facing behavior spec (Claude Code skill)
README.md                                 this file
scripts/
  backup.sh                               GitHub-backed project backup/sync
  history.sh                              conversation history / skills / config export-import
  migrate_gui.ps1                         standalone Windows Forms GUI (no AI required)
  Migrate.bat                             double-click launcher for migrate_gui.ps1
  vendor/claude-code-export-import/       vendored third-party tool (MIT) - see VENDORED-FROM.md
```

## Requirements

- **Git** (any recent version) — [git-scm.com](https://git-scm.com/downloads)
- **GitHub CLI (`gh`)**, authenticated (`gh auth login`) — [cli.github.com](https://cli.github.com/)
- **Windows** for `migrate_gui.ps1`/`Migrate.bat` (PowerShell 5.1, included).
  `backup.sh`/`history.sh` are plain bash and should work anywhere with
  `git`/`gh`/bash (macOS, Linux) even though the GUI is Windows-only.
- **Python 3.8+** (optional) — only for the experimental desktop-app
  fidelity-restore feature.

## Safety notes

- Every repo `init` creates is **private**. This tool never changes repo
  visibility.
- `sync` never force-pushes, never resets, never overwrites local
  uncommitted changes — conflicts are reported, not resolved for you.
- History export/import never touches your login credentials.
- The `migrate` flow sets `git config --global core.longpaths true` on
  Windows (needed for repos with long file paths) and reports it — a
  routine, reversible, standard git setting, not a system change.

## Credits

- `scripts/vendor/claude-code-export-import/` is vendored, unmodified, from
  [Dangelo123/claude-code-export-import](https://github.com/Dangelo123/claude-code-export-import)
  (MIT) — see [`scripts/vendor/claude-code-export-import/VENDORED-FROM.md`](scripts/vendor/claude-code-export-import/VENDORED-FROM.md)
  for the pinned commit and full attribution.
- Built with, and for, [Claude Code](https://claude.com/claude-code).

## License

[MIT](LICENSE) for this repository's own code (`SKILL.md`, `scripts/backup.sh`,
`scripts/history.sh`, `scripts/migrate_gui.ps1`, `scripts/Migrate.bat`).
The vendored third-party tool under `scripts/vendor/` carries its own MIT
license — see that folder.
