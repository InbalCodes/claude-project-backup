---
name: project-backup
description: "Back up project folders to private GitHub repos and sync them onto another machine, and/or migrate local Claude Code conversation history (~/.claude/projects) between machines via an export/import archive. Always presents a selection list and lets the user pick what to include before acting. Use when the user asks to back up their projects to git/GitHub, save work in progress across projects, migrate to a new computer, or continue conversations on another machine. Invoke as /project-backup init | backup | sync | history export | history import <archive> | migrate."
---

# Project Backup

Backs up project folders directly under the current working directory to
private GitHub repos, and lets those projects be synced onto another machine
later. Repos it creates are tagged with the GitHub topic
`claude-project-backup` so `sync` can discover them without a local manifest —
this makes syncing work from any machine, as long as `gh` is authenticated as
the same GitHub account.

Separately, `scripts/history.sh` handles one-time migration of local Claude
Code conversation history and custom skills between machines via a local
archive (never GitHub — see below).

**Hard rule: always list candidates and let the user pick before touching
anything, for all four flows (init/backup, sync, history export, history
import) — no exceptions, even if the user says "back up everything."** Every
mode below has a read-only `list*` command — run it first, present the
results as a selection, and only pass the names/items the user actually
chose to the action command. Never default to "everything" without showing
the list first, so the user can deselect anything unexpected (e.g. a
non-project folder).

## Selection UI

These lists routinely have more than 4 items, so **AskUserQuestion cannot be
used for them** (hard-capped at 4 options per question). Always build an
interactive checkbox list instead, using the `visualize` tool
(`show_widget`, HTML mode — call `read_me` once per session before the first
use): one row per candidate with a checkbox, its name, and a short status
label; pre-check sensible defaults (everything except `skip-*` rows for
`list`, nothing pre-checked for history export/import since that content is
larger and more sensitive — except when running as part of `migrate`,
where projects/skills also default to everything checked, per that
section's rationale; standalone `history export`/`history import` keep
this conservative default unchanged); a "confirm selection" button that calls
`sendPrompt(...)` with the chosen names spelled out in a plain instruction
(e.g. `"הרץ init על: name1, name2, ..."`) so the confirmed list comes back
as a normal chat message you can parse and act on. Group rows by status
(new / uncommitted / up-to-date, or not-local / clean / dirty / conflict)
with a small muted label per row — don't make the user cross-reference a
separate legend. This is the standard selection UI for this skill; don't
fall back to a plain text list or to AskUserQuestion just because it seems
simpler for a short list — consistency across runs matters more here.

The actual logic lives in `scripts/backup.sh` and `scripts/history.sh` (bash,
run via Git Bash / `bash`). Always run `backup.sh` with the user's projects
root as the working directory — normally wherever the user invoked this skill
from. Do not assume a fixed path.

## Prerequisites (check once, don't re-check every run)

- `gh` installed and authenticated (`gh auth status`). If not, tell the user
  to run `gh auth login` themselves — do not attempt to authenticate for them.
- `git` installed.

## Backing up projects to GitHub

Run via Bash tool: `bash "<skill_dir>/scripts/backup.sh" <mode> [args...]`,
with `ROOT_DIR` set to the user's projects folder if it differs from the
current directory (`ROOT_DIR=/path/to/projects bash .../backup.sh list`).

### 1. `list` — always run first for `init`/`backup`

Prints one line per folder directly under ROOT_DIR:
`name<TAB>status<TAB>detail`. Status is one of `skip-symlink`, `skip-empty`,
`new`, `no-remote`, `uncommitted-no-remote`, `uncommitted`, `up-to-date`.
Turn this into the checkbox widget described in "Selection UI" above
(pre-check everything except the `skip-*` rows as a sensible default, but let
the user deselect freely — flag anything that doesn't look like a real
project, e.g. non-code folders). If a folder contains its own nested `.git`
one or more levels down (a separate repo, possibly with its own remote and
history — verify with `git -C <nested> log`/`remote -v` before assuming),
flag it explicitly rather than letting it get silently absorbed: `init` now
auto-excludes nested repos via `.gitignore` and prints a `[warn:nested-repo]`
line, but the user should decide whether that nested folder needs backing up
as its own separate project (add it to the `list` candidates next time).

### 2. `init <names...>` — first-time backup of the selected folders

For each selected name:
- If it's not a git repo yet: `git init`, adds a generic `.gitignore` (only
  if none exists — never overwrites one the user already has), commits
  everything.
- If it's a git repo with uncommitted changes: commits them.
- If it has no GitHub remote: creates a **private** repo under the
  authenticated user's account with the same name as the folder, pushes, and
  tags it with the `claude-project-backup` topic.
- If it already has a remote: just makes sure everything committed is
  pushed, and tags the repo with the topic (so older, manually-created repos
  become visible to `sync` too).

Errors on names that don't exist or weren't selected — it never silently
processes anything beyond what's passed.

### 3. `backup <names...>` — manual incremental backup while working

Run `list` first here too. For each selected git repo: commits any
uncommitted changes with a timestamped message and pushes. A selected folder
that isn't a git repo yet is reported so the user knows to run `init` for it
first.

### 4. `list-remote` / `sync <names...>` — bring projects onto this machine

`list-remote` prints repos tagged `claude-project-backup` under the
authenticated account that aren't at up-to-date state locally:
`name<TAB>status<TAB>detail`, status one of `not-local`, `local-clean`,
`local-dirty`, `local-conflict`. Present with the same checkbox widget, then
`sync` the chosen names:
- `not-local` → clones it into ROOT_DIR.
- `local-clean` → pulls (fast-forward only).
- `local-dirty` → skipped, tell the user to commit or stash first (never
  overwrite local work).
- `local-conflict` (exists locally, not a git repo) → skipped, flag it
  explicitly.

## Migrating conversation history between machines

Claude Code's conversation history does **not** live inside project folders
— it lives centrally in `~/.claude/projects/<encoded-path>/`, one subfolder
per project keyed by that project's absolute path on this machine. Regular
git backup of a project folder never captures this. `scripts/history.sh`
handles it separately, as a one-time export/import, **not** via git/GitHub —
transcripts can contain anything ever typed or read into a session, so they
go through a local archive the user moves themselves (USB drive, a cloud
folder they already control), never pushed anywhere.

Items are selected as `p:<name>` (a project, from `list-projects`), `s:<name>`
(a skill, from `list-skills`), or `c:<name>` (global config, `settings` or
`plugins`, from `list-config`).

`c:settings` is `~/.claude/settings.json` (permissions, allowed-tools,
theme, marketplaces) and `c:plugins` is `~/.claude/plugins/` (installed
plugins + local marketplace sources) — both are small, non-secret, and
genuinely save reconfiguration work on a new machine. Deliberately **not**
offered as config items, ever: `.credentials.json` (the login token — the
user just logs back in on the new machine, their account/subscription
follows automatically) and `~/.claude.json` (mixes account metadata,
telemetry, and feature-flag caches with per-project trust flags — not
meaningful to copy wholesale; the user will just need to re-approve the
trust dialog once per project on the new machine, which is normal and not
worth engineering around).

### Export (run on the source machine)

1. `history.sh list-projects`, `history.sh list-skills`, and
   `history.sh list-config` — each prints `name<TAB>size<TAB>last-modified`.
   Present all three in the checkbox widget (grouped by kind: projects /
   skills / config) and let the user choose what to include. Don't
   pre-select everything by default for projects/skills — history can be
   large and sensitive, a deliberate choice matters more than for code
   projects — but config items (`settings`, `plugins`) are safe to
   pre-check, they're small and non-sensitive.
2. `history.sh export <output-dir> <selected p:name/s:name/c:name items>` — copies
   only the selected items (never `.credentials.json` or anything else in
   `~/.claude`) into a tar.gz. If `<output-dir>` is omitted the script
   defaults to `$HOME/claude-history-export-<timestamp>`, which is
   deliberately **outside** the projects root so `init`/`backup` never pick
   it up as a project to push to GitHub.
3. Tell the user exactly where the archive landed and that they need to move
   it themselves (USB drive, cloud folder) — don't assume a drive letter or
   path without asking.

### Import (run on the destination machine)

1. `history.sh list-archive <archive-or-dir>` — lists what's inside under
   `== projects ==` / `== skills ==` / `== config ==`. Present with the
   checkbox widget same as above.
2. `history.sh import <archive-or-dir> <selected items>` — restores only the
   selected items; never overwrites an existing local file/subfolder of the
   same name (this applies to `c:settings`/`c:plugins` too — a fresh
   machine's own settings.json is never clobbered).

**Path-matching caveat — always mention this when discussing migration:**
history for a project is only picked up automatically if the restored folder
name under `~/.claude/projects` matches the new machine's actual encoding of
that project's absolute path. If the new machine has a different Windows
username or drive layout, tell the user explicitly and offer the
(best-effort, unverified) fallback of renaming the folder to match the new
path's encoding — don't claim it's guaranteed to work.

## One-click migration (`/project-backup migrate`)

For a version that doesn't require an active Claude Code session, see
`scripts/migrate_gui.ps1` (double-click `scripts/Migrate.bat`) — a
standalone Windows Forms GUI covering the same phases below (prereqs,
sign-in, archive discovery, config restore, project sync, history
import, optional resume instructions) via a native checkbox UI instead
of this prose flow. The two aren't code-linked — keep them phase-aligned
when editing either.

`migrate` is the guided, single-flow version of "set this whole machine
up" — prereqs, config, project sync, and history import in one pass. It
still follows this file's hard rule (list first, let the user pick) at
every selection step; it doesn't replace `init`/`backup`/`sync`/`history
export`/`history import`, it sequences them.

1. **Scope.** Ask the user (a) the projects root directory explicitly —
   never assume cwd, this typically runs on a machine where cwd isn't
   meaningful yet — and (b) whether they want to attempt the resume/
   desktop-app step (below) now, since it's the most manual and
   disruptive part of the flow (multiple terminal + GUI interactions).
   Skip that step later if they opt out here.
2. **Prereqs.** `git --version`; if missing, tell the user to install it
   themselves, don't install it. `gh --version`; if the binary exists but
   isn't resolving (seen on Windows: installed but not on PATH), locate
   it, fix the current-process PATH and the User-scope PATH via
   PowerShell's `[Environment]::SetEnvironmentVariable` (not Bash — a
   Bash-session PATH won't pick up a registry change until a fresh
   shell), and report the fix in the final summary rather than asking
   permission for this specific step (it's a routine, reversible,
   per-user PATH addition). If `gh` isn't installed at all, tell the user
   to install it. `gh auth status`; if not authenticated, run
   `gh auth login --hostname github.com --git-protocol https --web` in
   the background, relay the printed device code + URL to the user, wait
   for them to complete it in their own browser — never complete OAuth
   itself.
3. **Locate the history archive.** Search `$HOME/Downloads`,
   `$HOME/Documents`, `$HOME/Desktop`, and `$HOME` for
   `claude-history-export-*.tar.gz` — don't assume it's in Downloads,
   it routinely isn't. One match → confirm with the user before using
   it. Zero or multiple matches → ask for the path directly. Skip this
   step if the user only wants project sync, not history.
4. **Config restore.** Run `history.sh import <archive> c:settings
   c:plugins` without extra ceremony — import never overwrites existing
   files, so this is safe to do early/unprompted.
5. **Project selection + sync.** `backup.sh list-remote` from the root
   dir chosen in step 1; checkbox widget, default all checked. Before
   running `sync`, set `git config --global core.longpaths true` on
   Windows and report it in the final summary (routine dev-tool config,
   not gated per-run — `sync`'s clone already passes
   `-c core.longpaths=true` per-invocation too, this is defense in
   depth). Run `backup.sh sync <selected names>`. **If a clone still
   fails with `Filename too long`** (e.g. a stale partial clone from
   before the config took effect), use this recovery runbook rather than
   improvising: `git config core.longpaths true` (per-repo, inside the
   partial clone dir) → `git restore --source=HEAD :/` → `git reset
   --hard HEAD`.
6. **History selection + import.** `history.sh list-archive <archive>`
   (reuse step 3's result if already fetched). Checkbox widget for
   `== projects ==` / `== skills ==`, **default all checked** — a
   deliberate exception to this file's base "don't pre-check
   projects/skills" guidance (see Selection UI above), scoped to
   `migrate` only. Run `history.sh import <archive> <selected p:/s:
   items>`. Restate the path-matching caveat above — different username
   or drive layout means restored history may not auto-show; best-effort
   folder-rename workaround, not guaranteed.
7. **Make history resumable in the desktop app** (only if the user
   opted in at step 1). Frame this as best-effort/manual throughout, not
   solved:
   - Check for the standalone `claude` CLI on PATH. If missing: ask
     before running `npm install -g @anthropic-ai/claude-code` (check
     `node`/`npm` first; if missing, tell the user to install Node
     themselves — same "never install without asking" rule as step 2's
     `git`/`gh` checks, since this is a new package install rather than
     a PATH/config fix).
   - Authenticate it (`claude auth login`) the same way as `gh auth
     login` — background, relay device code/URL, never complete OAuth
     itself.
   - Per restored project, output a numbered manual instruction block —
     this step cannot be run by the agent, `--resume`'s interactive
     picker doesn't work headless: open a terminal in the project folder
     → `claude --resume` → choose "Resume from summary" (or whichever
     prompt appears) → keep the desktop app open while doing this →
     after closing the terminal, an auto-archive toast appears in the
     app — click **Undo** on it to keep the session pinned (no CLI
     equivalent exists).
   - Print the "Known upstream limitations" block below verbatim so the
     user has accurate expectations.
8. **Final summary.** Extend the usual summarize-by-outcome convention
   (see Notes for Claude below) across all steps: prereqs fixed
   (PATH/longpaths changes listed) / config restored / projects
   synced-skipped-errored / history restored / manual follow-up still
   pending (list of projects awaiting a manual `claude --resume`, only
   if step 7 was attempted).

**Known upstream limitations (desktop app):** the Claude **desktop app**
does not scan `~/.claude/projects/` — it keeps a separate,
per-installation Electron IndexedDB session index, entirely disconnected
from the filesystem transcripts this skill restores. This is "working as
designed" per the app's own docs (each surface — desktop app, web, VS
Code extension — maintains its own separate session history). Confirmed
via anthropics/claude-code issues **#90423**, **#81835**, **#89781**
(all open, unresolved). There is no CLI command to fix this directly —
`claude project` only has `purge` (which deletes state, the opposite of
what's needed) — and resumed sessions land under "Other" in the sidebar
grouping rather than their project's group, a separate confirmed bug
(#89781). Quote these facts consistently rather than re-investigating
each run.

`migrate_gui.ps1` additionally offers an **experimental, opt-in, third-party**
path: `scripts/vendor/claude-code-export-import/` (vendored from
github.com/Dangelo123/claude-code-export-import, MIT) copies all three
places sidebar state actually lives — `local_*.json` records, `Local
Storage/leveldb`, and the `IndexedDB` store itself byte-for-byte — instead
of just the CLI transcripts. It needs Python (checked, never required) and
the desktop app closed during import. Its own docs claim `local_*.json`
alone is enough for a session to appear, which contradicts what this skill
found empirically (that folder didn't exist on a real test machine) — so
this may not work depending on app-version drift on either machine. Never
present it as a fix; it's a second experimental attempt alongside the
manual `claude --resume` workaround above, which remains the default.

## Notes for Claude

- Pushing isn't purely passive: a repo with `.github/workflows/*.yml` goes
  live the moment it's pushed — schedules and on-push triggers start
  actually running in GitHub's cloud, which can spam the user with failure
  emails for an experiment that was never meant to run unattended. `list`
  flags this per folder and `init` prints `[warn:has-workflows]` with the
  exact `gh workflow disable "<name>" --repo <owner>/<repo>` command after
  creating such a repo — surface that warning to the user immediately rather
  than letting them discover it later, and offer to disable the workflow if
  they don't want it running (disabling is reversible and safe to just do
  when they confirm; don't delete the workflow file unless asked).
- Never force-push, never `git reset --hard`, never overwrite local
  uncommitted changes during `sync`. If `sync` hits a conflict or diverged
  history, surface it to the user instead of resolving it silently.
- All repos created by `init` are **private**. Don't change repo visibility
  without the user explicitly asking.
- Folder name = repo name, always. If a folder name isn't a valid GitHub repo
  name (e.g. contains spaces), `gh repo create` will error — report that
  clearly rather than silently renaming anything.
- After running, summarize results grouped by outcome (backed up / already up
  to date / skipped / errors) rather than dumping the raw log.
