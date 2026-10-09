#!/usr/bin/env bash
# Syncs a repo's .vibe-wise/ with a per-repo folder in the Obsidian Vault.
#   pull   (UserPromptSubmit) — on /vibe-wise:learn: mark the session, Vault → repo
#   resume (SessionStart resume) — marked session reopened: Vault → repo
#   push   (SessionEnd)       — marked session closed: repo → Vault
# Reads the hook JSON on stdin. Never prints to stdout (UserPromptSubmit and
# SessionStart stdout is injected into the model context) and always exits 0.

set -u

mode="${1:-}"
state_dir="$HOME/.claude/vibe-wise-sync"
sessions_dir="$state_dir/sessions"
log_file="$state_dir/sync.log"

mkdir -p "$sessions_dir" 2>/dev/null || exit 0
exec >>"$log_file" 2>&1

log() { printf '%s [%s] %s\n' "$(date -Is)" "$mode" "$*"; }

input="$(cat)"

vault="${VIBE_WISE_VAULT:-}"
if [ -z "$vault" ] || [ "$vault" = "CHANGE_ME" ]; then
  exit 0
fi
if [ ! -d "$vault" ]; then
  log "vault path does not exist: $vault"
  exit 0
fi

field() {
  printf '%s' "$input" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    value = None
print(value if isinstance(value, str) else "")
' "$1"
}

session_id="$(field session_id)"
case "$session_id" in
  "" | *[!A-Za-z0-9_-]*)
    log "invalid session_id: '$session_id'"
    exit 0
    ;;
esac
marker="$sessions_dir/$session_id"

resolve_dirs() {
  local start="$1" common
  toplevel="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" || return 1
  common="$(git -C "$start" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  repo_name="$(basename "$(dirname "$common")")"
  local_dir="$toplevel/.vibe-wise"
  remote_dir="$vault/$repo_name"
  if [ -L "$local_dir" ] || [ -L "$remote_dir" ]; then
    log "refusing symlinked state dir: $local_dir or $remote_dir"
    return 1
  fi
}

do_pull() {
  if [ ! -d "$remote_dir" ]; then
    log "no vault folder yet for $repo_name, skipping pull"
    return 0
  fi
  mkdir -p "$local_dir" && rsync -rc --exclude desktop.ini "$remote_dir/" "$local_dir/" \
    && log "pulled $remote_dir -> $local_dir" \
    || log "pull failed for $repo_name"
}

do_push() {
  if [ ! -d "$local_dir" ]; then
    log "no local .vibe-wise in $toplevel, skipping push"
    return 0
  fi
  mkdir -p "$remote_dir" && rsync -rc --exclude desktop.ini "$local_dir/" "$remote_dir/" \
    && log "pushed $local_dir -> $remote_dir" \
    || log "push failed for $repo_name"
}

case "$mode" in
  pull)
    prompt="$(field prompt)"
    prompt="${prompt#"${prompt%%[![:space:]]*}"}"
    case "$prompt" in
      "/vibe-wise:learn" | "/vibe-wise:learn "* | "/vibe-wise:learn"$'\n'*) ;;
      *) exit 0 ;;
    esac
    resolve_dirs "$(field cwd)" || { log "cwd is not a git repo"; exit 0; }
    printf '%s\n' "$toplevel" >"$marker"
    do_pull
    ;;
  resume)
    [ -f "$marker" ] || exit 0
    resolve_dirs "$(head -n 1 "$marker")" || { log "marked repo no longer resolvable"; exit 0; }
    do_pull
    ;;
  push)
    [ -f "$marker" ] || exit 0
    resolve_dirs "$(head -n 1 "$marker")" || { log "marked repo no longer resolvable"; exit 0; }
    do_push
    ;;
  *)
    log "unknown mode"
    ;;
esac

exit 0
