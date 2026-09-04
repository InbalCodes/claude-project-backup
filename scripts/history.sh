#!/usr/bin/env bash
# project-backup history: list-projects | list-skills | list-config | export | list-archive | import
#
# One-time migration helper for Claude Code's local conversation history
# (~/.claude/projects), custom skills (~/.claude/skills), and select global
# config (~/.claude/settings.json, ~/.claude/plugins) between machines.
# Deliberately does NOT touch ~/.claude/.credentials.json, ~/.claude.json
# (mixes account/telemetry/cache state with per-project data, not portable
# as a whole), or anything else in ~/.claude — only the explicitly allowlisted
# items below, and only the ones the user actually selects.
#
# export/import only ever touch the items explicitly selected — callers (the
# skill) are expected to run list-projects/list-skills/list-config (or
# list-archive for import) first, let the user pick, then pass the chosen
# items as p:<name> (project) / s:<name> (skill) / c:<name> (config,
# "settings" or "plugins") arguments.
set -uo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
MODE="${1:-}"
shift || true

usage() {
  echo "Usage:"
  echo "  history.sh list-projects"
  echo "  history.sh list-skills"
  echo "  history.sh list-config"
  echo "  history.sh export <output-dir> <p:name|s:name|c:name ...>"
  echo "  history.sh list-archive <archive.tar.gz-or-dir>"
  echo "  history.sh import <archive.tar.gz-or-dir> <p:name|s:name|c:name ...>"
  exit 1
}

# name<TAB>size<TAB>mtime, one per subfolder of a given dir
list_subfolders() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  for d in "$dir"/*/; do
    [ -d "$d" ] || continue
    local name size mtime
    name="$(basename "$d")"
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
    mtime="$(date -r "$d" '+%Y-%m-%d' 2>/dev/null)"
    printf '%s\t%s\t%s\n' "$name" "$size" "$mtime"
  done
}

cmd_list_projects() { list_subfolders "$CLAUDE_DIR/projects"; }
cmd_list_skills() { list_subfolders "$CLAUDE_DIR/skills"; }

# Resolves an archive-or-dir source into $extracted (a plain directory),
# extracting to a temp dir into $tmp if $src was a .tar.gz/.tgz. Caller must
# rm -rf "$tmp" when done if it's non-empty.
resolve_archive() {
  local src="$1"
  tmp=""
  extracted="$src"
  if [[ "$src" == *.tar.gz || "$src" == *.tgz ]]; then
    tmp="$(mktemp -d)"
    # --force-local: without it, tar treats a Windows path's drive-letter
    # colon (C:\...) as a "host:path" remote-tar address and tries to
    # resolve "C" as a hostname instead of extracting the local file.
    tar -xzf "$src" -C "$tmp" --force-local
    extracted="$tmp/$(ls "$tmp" | head -n 1)"
  fi
}

# Config items are hand-picked, not "every top-level thing in ~/.claude" —
# most of that directory (cache, telemetry, debug, ide, session-env,
# shell-snapshots, sessions/*.key, mcp-needs-auth-cache.json, backups of
# ~/.claude.json, etc.) is transient or machine-specific and deliberately
# left out.
cmd_list_config() {
  if [ -f "$CLAUDE_DIR/settings.json" ]; then
    printf 'settings\t%s\t%s\n' \
      "$(du -sh "$CLAUDE_DIR/settings.json" 2>/dev/null | cut -f1)" \
      "$(date -r "$CLAUDE_DIR/settings.json" '+%Y-%m-%d' 2>/dev/null)"
  fi
  if [ -d "$CLAUDE_DIR/plugins" ]; then
    printf 'plugins\t%s\t%s\n' \
      "$(du -sh "$CLAUDE_DIR/plugins" 2>/dev/null | cut -f1)" \
      "$(date -r "$CLAUDE_DIR/plugins" '+%Y-%m-%d' 2>/dev/null)"
  fi
}

cmd_export() {
  local out="${1:-}"
  shift || true
  local items=("$@")
  [ -z "$out" ] && usage
  [ "${#items[@]}" -eq 0 ] && { echo "No items selected. Run list-projects/list-skills/list-config first and pass p:<name>/s:<name>/c:<name>."; exit 1; }

  mkdir -p "$out/projects" "$out/skills" "$out/config"
  local any=0
  for item in "${items[@]}"; do
    local kind="${item%%:*}" name="${item#*:}"
    case "$kind" in
      p)
        if [ -d "$CLAUDE_DIR/projects/$name" ]; then
          cp -a "$CLAUDE_DIR/projects/$name" "$out/projects/$name"
          echo "[included] project: $name"
          any=1
        else
          echo "[ERROR] no such project history: $name"
        fi
        ;;
      s)
        if [ -d "$CLAUDE_DIR/skills/$name" ]; then
          cp -a "$CLAUDE_DIR/skills/$name" "$out/skills/$name"
          echo "[included] skill: $name"
          any=1
        else
          echo "[ERROR] no such skill: $name"
        fi
        ;;
      c)
        case "$name" in
          settings)
            if [ -f "$CLAUDE_DIR/settings.json" ]; then
              cp -a "$CLAUDE_DIR/settings.json" "$out/config/settings.json"
              echo "[included] config: settings"
              any=1
            else
              echo "[ERROR] no settings.json found"
            fi
            ;;
          plugins)
            if [ -d "$CLAUDE_DIR/plugins" ]; then
              cp -a "$CLAUDE_DIR/plugins" "$out/config/plugins"
              echo "[included] config: plugins"
              any=1
            else
              echo "[ERROR] no plugins directory found"
            fi
            ;;
          *) echo "[ERROR] unknown config item: $name (expected settings or plugins)" ;;
        esac
        ;;
      *) echo "[ERROR] bad item (expected p:name, s:name, or c:name): $item" ;;
    esac
  done
  [ "$any" -eq 1 ] || { echo "Nothing was included, aborting."; rm -rf "$out"; exit 1; }

  cat > "$out/README.txt" <<'EOF'
Claude Code migration export
=============================
Contents (only what was explicitly selected at export time):
  projects/  - local conversation history (session transcripts + memory) for
               the selected projects, named after each project's absolute
               path on THIS machine (':' and '/' or '\' replaced with '-').
  skills/    - the selected custom skills.
  config/    - selected global config: settings.json (permissions, theme,
               marketplaces) and/or plugins/ (installed plugins + local
               marketplace sources).

Deliberately NOT included, ever: ~/.claude/.credentials.json (the Claude
Code login token — on the new machine just log in again, your account and
subscription carry over automatically) and ~/.claude.json (mixes account
metadata, telemetry, and feature-flag caches with per-project trust state;
not meaningful to copy wholesale — on the new machine you'll just need to
re-approve the trust dialog the first time you open each project, which is
normal). Also not included: cache, telemetry, debug, ide, session-env,
shell-snapshots, and anything not explicitly selected.

To restore on the new machine, run:
  bash history.sh list-archive <this-folder-or-its-.tar.gz>
  bash history.sh import <this-folder-or-its-.tar.gz> <selected items>

IMPORTANT — path matching:
Claude Code only recognizes a project's history if that project folder name
under ~/.claude/projects exactly encodes the project's absolute path on the
NEW machine. If the new machine has a different Windows username or drive
layout than this one, a restored history folder won't automatically show up
for the matching project. If that happens, you (or a Claude Code session on
the new machine) can try renaming the restored subfolder under
~/.claude/projects to match the new machine's actual path, using the same
substitution pattern (":" and path separators -> "-"). This is a best-effort
workaround, not guaranteed — verify it worked before relying on it.
EOF

  # --force-local: see resolve_archive() above - same Windows drive-letter
  # gotcha applies here when $out is a native Windows path.
  tar -czf "$out.tar.gz" -C "$(dirname "$out")" "$(basename "$out")" --force-local
  local size
  size="$(du -sh "$out.tar.gz" | cut -f1)"
  rm -rf "$out"

  echo "[done] Export written to: $out.tar.gz ($size)"
  echo "Copy this file to your USB drive. Nothing else needs to be included — credentials were never touched."
}

cmd_list_archive() {
  local src="${1:-}"
  [ -z "$src" ] && usage
  local tmp extracted
  resolve_archive "$src"
  echo "== projects =="
  list_subfolders "$extracted/projects"
  echo "== skills =="
  list_subfolders "$extracted/skills"
  echo "== config =="
  [ -f "$extracted/config/settings.json" ] && printf 'settings\t%s\t\n' "$(du -sh "$extracted/config/settings.json" 2>/dev/null | cut -f1)"
  [ -d "$extracted/config/plugins" ] && printf 'plugins\t%s\t\n' "$(du -sh "$extracted/config/plugins" 2>/dev/null | cut -f1)"
  [ -n "$tmp" ] && rm -rf "$tmp"
}

cmd_import() {
  local src="${1:-}"
  shift || true
  local items=("$@")
  [ -z "$src" ] && usage
  [ "${#items[@]}" -eq 0 ] && { echo "No items selected. Run list-archive first and pass p:<name>/s:<name>."; exit 1; }

  local tmp extracted
  resolve_archive "$src"
  [ -d "$extracted" ] || { echo "Not found: $extracted"; exit 1; }

  mkdir -p "$CLAUDE_DIR/projects" "$CLAUDE_DIR/skills"

  for item in "${items[@]}"; do
    local kind="${item%%:*}" name="${item#*:}"
    local src_path dest_path label
    case "$kind" in
      p) src_path="$extracted/projects/$name"; dest_path="$CLAUDE_DIR/projects/$name"; label="project" ;;
      s) src_path="$extracted/skills/$name"; dest_path="$CLAUDE_DIR/skills/$name"; label="skill" ;;
      c)
        case "$name" in
          settings) src_path="$extracted/config/settings.json"; dest_path="$CLAUDE_DIR/settings.json"; label="config" ;;
          plugins) src_path="$extracted/config/plugins"; dest_path="$CLAUDE_DIR/plugins"; label="config" ;;
          *) echo "[ERROR] unknown config item: $name (expected settings or plugins)"; continue ;;
        esac
        ;;
      *) echo "[ERROR] bad item (expected p:name, s:name, or c:name): $item"; continue ;;
    esac

    if [ ! -e "$src_path" ]; then
      echo "[ERROR] not in archive: $label $name"
    elif [ -e "$dest_path" ]; then
      echo "[skip:exists] $label $name (already present locally — not overwritten)"
    else
      cp -a "$src_path" "$dest_path"
      echo "[restored] $label $name"
    fi
  done

  [ -n "$tmp" ] && rm -rf "$tmp"

  echo ""
  echo "Reminder: history for a project only shows up automatically if its"
  echo "folder name under ~/.claude/projects matches this machine's actual"
  echo "path encoding. See README.txt in the export for details."
}

case "$MODE" in
  list-projects) cmd_list_projects ;;
  list-skills) cmd_list_skills ;;
  list-config) cmd_list_config ;;
  export) cmd_export "$@" ;;
  list-archive) cmd_list_archive "$@" ;;
  import) cmd_import "$@" ;;
  *) usage ;;
esac
