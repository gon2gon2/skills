#!/bin/sh
# orca-worktree-guard.sh — PreToolUse hook for Claude Code and Codex
#
# Blocks `git worktree remove` on a worktree Orca manages, before it runs, and suggests
# the `orca worktree rm` command instead. Paths Orca does not know about pass through.
#
# Input: the hook payload (JSON) on stdin; reads `tool_input.command`.
#        If command is an array (as in Codex), checks the script of `bash -lc <script>`,
#        otherwise the joined string.
# Output: when blocking, a message on stderr and exit 2. Otherwise exit 0.
#
# Fails open when it cannot decide: jq or orca missing, or the Orca app not responding.
# This guards against mistakes; it is not a security boundary. It cannot see paths built
# from variables or $(...).
#
# Bypass: prefix the command with `ORCA_WT_GUARD=off`, or set ORCA_WT_GUARD=off in the environment.

set -u

[ "${ORCA_WT_GUARD-}" = off ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '
  (.tool_input.command // .tool_input.cmd // .command // empty)
  | if type == "array" then
      (if length >= 3 and (.[-2] | tostring | test("^-[a-z]*c$")) then .[-1] else join(" ") end)
    else tostring end' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Fast path: unrelated commands never call orca.
case "$cmd" in *worktree*remove*) ;; *) exit 0 ;; esac
case "$cmd" in *ORCA_WT_GUARD=off*) exit 0 ;; esac

base=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$base" ] || base=$PWD

# Tokenizes the shell command and extracts only `cd DIR` and
# `git [-C DIR] worktree remove [opts] TARGET`.
# One line per hit: "cd<TAB>DIR" or "rm<TAB>CDIR<TAB>TARGET". Never evals.
targets=$(printf '%s\n' "$cmd" | awk -v SQ="'" '
function flush_tok() { if (have) { toks[n++] = tok }; tok = ""; have = 0 }
function flush_seg(   i, t, w, cdir, sub_, target) {
  flush_tok()
  i = 0
  # Skip what can precede the command: shell keywords, variable assignments, and wrappers
  # (command, env, sudo, exec, nohup, time, builtin) with their options.
  while (i < n) {
    if (toks[i] ~ /^(if|then|else|elif|while|until|do)$/ || toks[i] == "{" || toks[i] == "!") { i++; continue }
    if (toks[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    if (toks[i] ~ /^(command|env|sudo|exec|nohup|time|builtin)$/) {
      w = toks[i]; i++
      while (i < n && toks[i] ~ /^-/ && toks[i] != "--") {
        # sudo -u USER and -g GROUP take a value.
        if (w == "sudo" && (toks[i] == "-u" || toks[i] == "-g")) i++
        i++
      }
      if (i < n && toks[i] == "--") i++
      continue
    }
    break
  }
  if (i < n && toks[i] == "cd") {
    printf "cd\t%s\n", (i + 1 < n ? toks[i + 1] : "~")
  } else if (i < n && toks[i] ~ /(^|\/)git$/) {
    i++; cdir = ""
    while (i < n && toks[i] ~ /^-/) {
      t = toks[i]
      if (t == "-C" && i + 1 < n) { cdir = (cdir == "" || toks[i + 1] ~ /^\// ? toks[i + 1] : cdir "/" toks[i + 1]); i += 2; continue }
      if ((t == "-c" || t == "--git-dir" || t == "--work-tree" || t == "--namespace") && i + 1 < n) { i += 2; continue }
      i++
    }
    if (i + 1 < n && toks[i] == "worktree" && toks[i + 1] == "remove") {
      i += 2; target = ""
      while (i < n) {
        if (toks[i] == "--") { if (i + 1 < n) target = toks[i + 1]; break }
        if (toks[i] !~ /^-/) { target = toks[i]; break }
        i++
      }
      if (target != "") printf "rm\t%s\t%s\n", (cdir == "" ? "." : cdir), target
    }
  }
  n = 0; delete toks
}
BEGIN { n = 0; tok = ""; have = 0; q = ""; hd = ""; hdpending = ""; hdtabs = 0 }
{
  # A heredoc body is data, not commands. Skip it until the delimiter line.
  if (hd != "") {
    t = $0
    if (hdtabs) sub(/^\t+/, "", t)
    if (t == hd) hd = ""
    next
  }
  line = $0 "\n"
  L = length(line)
  for (p = 1; p <= L; p++) {
    c = substr(line, p, 1)
    if (q == "" && c == "<" && substr(line, p + 1, 1) == "<" && substr(line, p + 2, 1) != "<") {
      p += 2; hdtabs = 0
      if (substr(line, p, 1) == "-") { hdtabs = 1; p++ }
      while (substr(line, p, 1) == " " || substr(line, p, 1) == "\t") p++
      w = ""
      while (p <= L) {
        c = substr(line, p, 1)
        if (c == " " || c == "\t" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">" || c == "\n") break
        if (c != SQ && c != "\"" && c != "\\") w = w c
        p++
      }
      p--
      if (w != "") hdpending = w
      continue
    }
    if (q == "'\''") { if (c == "'\''") q = ""; else tok = tok c; continue }
    if (q == "\"") {
      if (c == "\"") q = ""
      else if (c == "\\" && p < L) { p++; tok = tok substr(line, p, 1) }
      else tok = tok c
      continue
    }
    if (c == "\\" && p < L) { p++; c = substr(line, p, 1); if (c != "\n") { tok = tok c; have = 1 }; continue }
    if (c == "'\''" || c == "\"") { q = c; have = 1; continue }
    # A # that starts a token begins a comment; drop the rest of the line. In a#b it is an ordinary character.
    if (c == "#" && !have) { p = L - 1; continue }
    if (c == " " || c == "\t") { flush_tok(); continue }
    if (c == ";" || c == "&" || c == "|" || c == "\n" || c == "(" || c == ")") { flush_seg(); continue }
    tok = tok c; have = 1
  }
  if (hdpending != "") { hd = hdpending; hdpending = "" }
}
END { flush_seg() }
')
[ -n "$targets" ] || exit 0

# Make a path absolute. If the directory exists, resolve symlinks too; otherwise join it as written.
resolve() { # resolve BASE PATH
  p=$2
  case "$p" in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac
  case "$p" in /*) ;; *) p=$1/$p ;; esac
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
  else printf '%s\n' "$p"; fi
}

command -v orca >/dev/null 2>&1 || exit 0
orca_json=$(orca worktree list --limit 10000 --json 2>/dev/null) || exit 0
managed=$(printf '%s' "$orca_json" | jq -r '.result.worktrees[]? | select((.hostId // "local") == "local") | .path' 2>/dev/null) || exit 0
[ -n "$managed" ] || exit 0

managed_resolved=$(printf '%s\n' "$managed" | while IFS= read -r m; do [ -n "$m" ] && resolve / "$m"; done)

tab=$(printf '\t')
blocked=""
cur=$base
while IFS="$tab" read -r kind a b; do
  case "$kind" in
    cd) cur=$(resolve "$cur" "$a") ;;
    rm)
      dir=$(resolve "$cur" "$a")
      t=$(resolve "$dir" "$b")
      if printf '%s\n' "$managed_resolved" | grep -Fxq -- "$t"; then
        blocked="$blocked$t
"
      else
        # git also finds a worktree by its last path component when that name is unique, from any
        # directory. Block a bare name that matches exactly one managed path; git refuses two or more.
        case "$b" in
          */*) ;;
          *)
            m=$(printf '%s\n' "$managed" | WT_NAME=$b awk '
              { p = $0; sub(/\/+$/, "", p); k = split(p, part, "/"); if (part[k] == ENVIRON["WT_NAME"]) { hits++; hit = p } }
              END { if (hits == 1) print hit }')
            [ -n "$m" ] && blocked="$blocked$(resolve / "$m")
"
            ;;
        esac
      fi
      ;;
  esac
done <<TARGETS
$targets
TARGETS

[ -n "$blocked" ] || exit 0

{
  echo "Blocked by orca-worktree-guard: Orca manages this worktree."
  echo "\`git worktree remove\` deletes the folder but leaves the workspace registered in Orca."
  echo "Remove it through Orca instead:"
  printf '%s' "$blocked" | while IFS= read -r t; do
    [ -n "$t" ] && echo "  orca worktree rm --worktree \"path:$t\""
  done
  echo "To bypass once, prefix the command with ORCA_WT_GUARD=off."
} >&2
exit 2
