#!/usr/bin/env bash
# project-backup: list | list-remote | init [names...] | backup [names...] | sync [names...]
# Backs up project folders directly under ROOT_DIR to private GitHub repos
# (owner = the authenticated `gh` user), and can sync them onto another
# machine. Repos created by this tool are tagged with TOPIC so `sync` can
# find them on GitHub without needing a local manifest.
#
# `init`/`backup`/`sync` only ever touch the folder/repo names explicitly
# passed as arguments — callers (the skill) are expected to run `list` /
# `list-remote` first, let the user pick, then pass the chosen names.
set -uo pipefail

ROOT_DIR="${ROOT_DIR:-$(pwd)}"
TOPIC="claude-project-backup"
MODE="${1:-}"
shift || true

cd "$ROOT_DIR" || { echo "ROOT_DIR not found: $ROOT_DIR"; exit 1; }

GITHUB_USER="$(gh api user --jq .login 2>/dev/null)"
if [ -z "$GITHUB_USER" ]; then
  echo "gh is not authenticated. Run: gh auth login"
  exit 1
fi

DEFAULT_GITIGNORE='node_modules/
__pycache__/
.venv/
venv/
env/
.env
.env.*
dist/
build/
*.log
.DS_Store
Thumbs.db
.idea/
.vscode/
*.pyc
'

is_empty_dir() {
  [ -z "$(find "$1" -type f 2>/dev/null | head -n 1)" ]
}

# A pushed repo isn't purely passive if it has GitHub Actions workflows —
# they go live and actually run in the cloud (schedules, on-push triggers)
# the moment the repo is created. Surface that before the user commits to it.
has_workflows() {
  [ -n "$(find "$1/.github/workflows" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | head -n 1)" ]
}

ensure_gitignore() {
  local dir="$1"
  if [ ! -f "$dir/.gitignore" ]; then
    printf '%s' "$DEFAULT_GITIGNORE" > "$dir/.gitignore"
  fi
}

# Any nested folder with its own .git would otherwise get silently absorbed
# by `git add -A` as a broken gitlink (no real content pushed). Exclude it
# and tell the caller so a human can decide whether it needs its own backup.
exclude_nested_repos() {
  local dir="$1" nested rel
  while IFS= read -r nested; do
    [ -z "$nested" ] && continue
    rel="${nested%/.git}"
    rel="${rel#"$dir"/}"
    if ! grep -qxF "$rel/" "$dir/.gitignore" 2>/dev/null; then
      printf '%s/\n' "$rel" >> "$dir/.gitignore"
    fi
    echo "[warn:nested-repo] $dir/$rel is its own git repo — excluded, back it up separately if needed"
  done < <(find "$dir" -mindepth 2 -maxdepth 4 -type d -name .git 2>/dev/null)
}

commit_if_dirty() {
  local dir="$1" msg="$2"
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    if ! git -C "$dir" add -A; then
      echo "[ERROR] $dir: git add failed, skipping commit"
      return 2
    fi
    if ! git -C "$dir" commit -q -m "$msg"; then
      echo "[ERROR] $dir: git commit failed"
      return 2
    fi
    return 0
  fi
  return 1
}

has_remote() {
  git -C "$1" remote get-url origin >/dev/null 2>&1
}

push_current_branch() {
  local dir="$1"
  local branch
  branch="$(git -C "$dir" branch --show-current)"
  git -C "$dir" push -q -u origin "$branch" 2>&1
}

create_remote_and_push() {
  local dir="$1" name="$2"
  (cd "$dir" && gh repo create "$GITHUB_USER/$name" --private --source=. --remote=origin --push)
}

# Extracts "owner/repo" from a folder's origin URL (which may point to a repo
# whose GitHub name differs from the local folder name) so tagging targets
# the real repo instead of guessing GITHUB_USER/<folder-name>.
remote_owner_repo() {
  local dir="$1" url
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  url="${url#https://github.com/}"
  url="${url#git@github.com:}"
  printf '%s' "$url"
}

tag_topic() {
  local owner_repo="$1"
  gh repo edit "$owner_repo" --add-topic "$TOPIC" >/dev/null 2>&1
}

# Prints name<TAB>status<TAB>detail for every candidate folder directly under
# ROOT_DIR, so the caller can present a selection list before doing anything.
cmd_list() {
  for dir in */; do
    dir="${dir%/}"
    [ -L "$dir" ] && { printf '%s\tskip-symlink\t\n' "$dir"; continue; }
    if is_empty_dir "$dir"; then printf '%s\tskip-empty\t\n' "$dir"; continue; fi

    local wf=""
    has_workflows "$dir" && wf=" [has GitHub Actions workflows — will run live in the cloud once pushed]"

    if [ ! -d "$dir/.git" ]; then
      printf '%s\tnew\twill git-init, commit, create private repo, push%s\n' "$dir" "$wf"
      continue
    fi

    local dirty remote
    dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l)"
    remote="$(git -C "$dir" remote get-url origin 2>/dev/null)"
    if [ -z "$remote" ]; then
      if [ "$dirty" -gt 0 ]; then
        printf '%s\tuncommitted-no-remote\t%s changes, will commit + create repo + push%s\n' "$dir" "$dirty" "$wf"
      else
        printf '%s\tno-remote\twill create repo + push%s\n' "$dir" "$wf"
      fi
    else
      if [ "$dirty" -gt 0 ]; then
        printf '%s\tuncommitted\t%s changes, will commit + push to %s%s\n' "$dir" "$dirty" "$remote" "$wf"
      else
        printf '%s\tup-to-date\talready pushed to %s%s\n' "$dir" "$remote" "$wf"
      fi
    fi
  done
}

# Prints name<TAB>url for every repo tagged with TOPIC on GitHub, plus
# whether it already exists locally, so the caller can present a selection
# list before cloning/pulling anything.
cmd_list_remote() {
  local rows
  rows="$(gh repo list "$GITHUB_USER" --topic "$TOPIC" --limit 200 --json name,url --jq '.[] | .name + "\t" + .url')"
  [ -z "$rows" ] && return
  while IFS=$'\t' read -r name url; do
    [ -z "$name" ] && continue
    if [ ! -e "$name" ]; then
      printf '%s\tnot-local\twill clone from %s\n' "$name" "$url"
    elif [ -d "$name/.git" ]; then
      if [ -n "$(git -C "$name" status --porcelain 2>/dev/null)" ]; then
        printf '%s\tlocal-dirty\thas uncommitted changes, would be skipped\n' "$name"
      else
        printf '%s\tlocal-clean\twould be pulled\n' "$name"
      fi
    else
      printf '%s\tlocal-conflict\texists locally but is not a git repo\n' "$name"
    fi
  done <<< "$rows"
}

cmd_init() {
  local names=("$@")
  [ "${#names[@]}" -eq 0 ] && { echo "No project names given. Run 'list' first and pass selected names."; exit 1; }
  echo "== project-backup init ($ROOT_DIR, github.com/$GITHUB_USER) =="
  for dir in "${names[@]}"; do
    if [ ! -d "$dir" ]; then echo "[ERROR] no such folder: $dir"; continue; fi
    if [ -L "$dir" ]; then echo "[skip:symlink] $dir"; continue; fi
    if is_empty_dir "$dir"; then echo "[skip:empty] $dir"; continue; fi

    if [ ! -d "$dir/.git" ]; then
      git -C "$dir" init -q -b main
      echo "[git-init] $dir"
    fi
    git -C "$dir" config core.longpaths true

    ensure_gitignore "$dir"
    exclude_nested_repos "$dir"
    if commit_if_dirty "$dir" "Initial backup commit"; then
      echo "[commit] $dir"
    fi

    if ! has_remote "$dir"; then
      if create_remote_and_push "$dir" "$dir"; then
        tag_topic "$GITHUB_USER/$dir"
        echo "[created+pushed] $dir -> github.com/$GITHUB_USER/$dir"
        if has_workflows "$dir"; then
          echo "[warn:has-workflows] $dir has .github/workflows — they are now live and will run in the cloud (schedules, on-push, etc). To stop one: gh workflow disable \"<name>\" --repo $GITHUB_USER/$dir"
        fi
      else
        echo "[ERROR] failed to create/push repo for $dir"
      fi
    else
      push_current_branch "$dir" >/dev/null 2>&1
      local owner_repo
      owner_repo="$(remote_owner_repo "$dir")"
      if [[ "$owner_repo" == "$GITHUB_USER"/* ]]; then
        tag_topic "$owner_repo"
      else
        echo "[note] $dir -> $owner_repo is not owned by $GITHUB_USER, skipping topic tag (won't appear in 'sync')"
      fi
      echo "[already-backed-up] $dir -> $owner_repo"
    fi
  done
}

cmd_backup() {
  local names=("$@")
  [ "${#names[@]}" -eq 0 ] && { echo "No project names given. Run 'list' first and pass selected names."; exit 1; }
  echo "== project-backup backup ($ROOT_DIR) =="
  local ts
  ts="$(date '+%Y-%m-%d %H:%M')"
  for dir in "${names[@]}"; do
    if [ ! -d "$dir" ]; then echo "[ERROR] no such folder: $dir"; continue; fi
    [ -L "$dir" ] && continue
    [ -d "$dir/.git" ] || { echo "[skip:no-git] $dir (run 'init' first)"; continue; }

    if commit_if_dirty "$dir" "Backup: $ts"; then
      if has_remote "$dir"; then
        push_current_branch "$dir" >/dev/null 2>&1 && echo "[backed-up] $dir"
      else
        echo "[committed-only] $dir (no remote — run 'init' to create one)"
      fi
    else
      echo "[clean] $dir"
    fi
  done
}

cmd_sync() {
  local names=("$@")
  [ "${#names[@]}" -eq 0 ] && { echo "No project names given. Run 'list-remote' first and pass selected names."; exit 1; }
  echo "== project-backup sync ($ROOT_DIR) =="
  local rows
  rows="$(gh repo list "$GITHUB_USER" --topic "$TOPIC" --limit 200 --json name,url --jq '.[] | .name + "\t" + .url')"
  if [ -z "$rows" ]; then
    echo "No repos tagged '$TOPIC' found for $GITHUB_USER."
    return
  fi

  for want in "${names[@]}"; do
    local url=""
    while IFS=$'\t' read -r name u; do
      [ "$name" = "$want" ] && url="$u"
    done <<< "$rows"

    if [ -z "$url" ]; then
      echo "[ERROR] no backed-up project named '$want' found on GitHub"
      continue
    fi

    if [ ! -e "$want" ]; then
      git -c core.longpaths=true clone -q "$url" "$want" && echo "[cloned] $want"
    elif [ -d "$want/.git" ]; then
      if [ -n "$(git -C "$want" status --porcelain 2>/dev/null)" ]; then
        echo "[skip:local-changes] $want (commit or stash first)"
      else
        if git -C "$want" pull -q --ff-only 2>&1; then
          echo "[pulled] $want"
        else
          echo "[ERROR] $want: pull failed (diverged history?)"
        fi
      fi
    else
      echo "[skip:conflict] $want exists locally and is not a git repo"
    fi
  done
}

case "$MODE" in
  list) cmd_list ;;
  list-remote) cmd_list_remote ;;
  init) cmd_init "$@" ;;
  backup) cmd_backup "$@" ;;
  sync) cmd_sync "$@" ;;
  *) echo "Usage: backup.sh {list|list-remote|init <names...>|backup <names...>|sync <names...>}"; exit 1 ;;
esac
