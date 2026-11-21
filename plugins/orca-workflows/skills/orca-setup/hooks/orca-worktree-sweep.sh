#!/bin/sh
# orca-worktree-sweep.sh — SessionStart hook for Claude Code and Codex
#
# Tells the agent when a worktree cleanup pass is due. Read-only: it never removes or changes
# a worktree, a branch or a card. The agent runs the pass itself, following the cleanup rule
# in its instructions.
#
# Input: the hook payload (JSON) on stdin; reads `cwd` and `source`.
# Output: at most one line on stdout, which both agents add to the model's context, and exit 0.
#
# It prints the line only when all of these hold:
#   - the session's cwd is the main worktree of a repository Orca knows, or a folder inside it
#     (in another worktree, or outside Orca, it prints nothing);
#   - that repository has at least one other worktree on this machine;
#   - it has not printed for that repository in the last 24 hours;
#   - the session is not continuing after a compaction (`source` is not `compact`).
#
# The only command it runs against Orca is `orca worktree ps --limit 10000 --json`. It makes no
# network calls and does not use gh.
#
# State: one stamp file per repository, holding the time of the last notice, in
#   ${XDG_STATE_HOME:-$HOME/.local/state}/orca-worktree-sweep/<repoId>.stamp
# If the stamp cannot be written it prints nothing, so it never repeats within 24 hours.
#
# Fails open when it cannot decide: jq or orca missing, or the Orca app not responding.
# Turn it off for one session by setting ORCA_WT_SWEEP=off in the environment.

set -u

[ "${ORCA_WT_SWEEP-}" = off ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
[ "$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)" = compact ] && exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

# Make a path absolute. If the directory exists, resolve symlinks too; otherwise join it as written.
resolve() { # resolve BASE PATH
  p=$2
  case "$p" in /*) ;; *) p=$1/$p ;; esac
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
  else printf '%s\n' "$p"; fi
}
cwd=$(resolve "$PWD" "$cwd")

command -v orca >/dev/null 2>&1 || exit 0
orca_json=$(orca worktree ps --limit 10000 --json 2>/dev/null) || exit 0
# One line per worktree on this machine: repoId, 1 for a main worktree or 0, path.
rows=$(printf '%s' "$orca_json" | jq -r '
  .result.worktrees[]?
  | select((.hostId // "local") == "local" and (.repoId | type) == "string" and (.path | type) == "string")
  | [.repoId, (if .isMainWorktree == true then "1" else "0" end), .path] | @tsv' 2>/dev/null) || exit 0
[ -n "$rows" ] || exit 0

# The worktree the session is in is the one with the longest path that contains cwd.
tab=$(printf '\t')
here="" here_repo="" here_main=""
while IFS="$tab" read -r repo main path; do
  [ -n "$path" ] || continue
  r=$(resolve / "$path")
  case "$cwd/" in "$r"/*) ;; *) continue ;; esac
  if [ "${#r}" -gt "${#here}" ]; then here=$r here_repo=$repo here_main=$main; fi
done <<ROWS
$rows
ROWS
[ "$here_main" = 1 ] || exit 0

total=0 missing=0
while IFS="$tab" read -r repo main path; do
  [ "$repo" = "$here_repo" ] && [ "$main" = 0 ] && [ -n "$path" ] || continue
  total=$((total + 1))
  [ -d "$path" ] || missing=$((missing + 1))
done <<ROWS
$rows
ROWS
[ "$total" -gt 0 ] || exit 0

state=${XDG_STATE_HOME:-${HOME-}/.local/state}/orca-worktree-sweep
stamp=$state/$(printf '%s' "$here_repo" | tr -c 'A-Za-z0-9._-' '_').stamp
now=$(date +%s 2>/dev/null) || exit 0
case "$now" in '' | *[!0-9]*) exit 0 ;; esac
last=$(cat "$stamp" 2>/dev/null)
case "$last" in '' | *[!0-9]*) last=0 ;; esac
[ $((now - last)) -ge 86400 ] || exit 0
mkdir -p "$state" 2>/dev/null || exit 0
(printf '%s\n' "$now" > "$stamp") 2>/dev/null || exit 0

note=""
[ "$(printf '%s' "$orca_json" | jq -r '.result.truncated // false' 2>/dev/null)" = true ] &&
  note=" Orca's list was truncated, so the counts may be low."
printf '%s\n' "Orca worktree cleanup pass due for $here: non-primary worktrees on this machine: $total, missing folders: $missing.$note Run the cleanup pass from your instructions on the first turn of this session. (orca-worktree-sweep: read-only, at most one notice per repository every 24 hours.)"
exit 0
