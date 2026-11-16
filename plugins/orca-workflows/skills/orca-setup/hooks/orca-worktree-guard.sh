#!/bin/sh
# orca-worktree-guard.sh — Claude Code / Codex PreToolUse 훅
#
# Orca 가 관리하는 워크트리를 `git worktree remove` 로 지우려 하면 실행 전에 막고
# `orca worktree rm` 명령을 알려 준다. Orca 에 등록되지 않은 경로는 그대로 통과한다.
#
# 입력: stdin 으로 훅 payload(JSON). `tool_input.command` 를 읽는다.
#       Codex 처럼 command 가 배열이면 `bash -lc <script>` 의 script 를, 아니면 이어 붙인 문자열을 본다.
# 출력: 막을 때 stderr 에 안내를 쓰고 exit 2. 그 밖에는 exit 0.
#
# 판단할 수 없으면 통과시킨다(fail open): jq 나 orca 가 없거나, Orca 앱이 응답하지 않을 때.
# 이 훅은 실수를 줄이는 장치이지 보안 경계가 아니다. 변수 확장이나 $(...) 로 만든 경로는 보지 못한다.
#
# 우회: 명령 앞에 `ORCA_WT_GUARD=off` 를 붙이거나 환경 변수 ORCA_WT_GUARD=off.

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

# 빠른 통과: 관련 없는 명령은 orca 를 부르지 않는다.
case "$cmd" in *worktree*remove*) ;; *) exit 0 ;; esac
case "$cmd" in *ORCA_WT_GUARD=off*) exit 0 ;; esac

base=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$base" ] || base=$PWD

# 셸 명령을 토큰으로 나눠 `cd DIR` 과 `git [-C DIR] worktree remove [opts] TARGET` 만 뽑는다.
# 출력 한 줄: "cd<TAB>DIR" 또는 "rm<TAB>CDIR<TAB>TARGET". eval 하지 않는다.
targets=$(printf '%s\n' "$cmd" | awk -v SQ="'" '
function flush_tok() { if (have) { toks[n++] = tok }; tok = ""; have = 0 }
function flush_seg(   i, t, cdir, sub_, target) {
  flush_tok()
  i = 0
  # 앞의 변수 대입과 감싸는 명령(command, env, sudo, exec, nohup, time, builtin)과 그 옵션을 건너뛴다.
  while (i < n) {
    if (toks[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    if (toks[i] ~ /^(command|env|sudo|exec|nohup|time|builtin)$/) {
      i++
      while (i < n && toks[i] ~ /^-/ && toks[i] != "--") i++
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
      if (t == "-c" && i + 1 < n) { i += 2; continue }
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
  # heredoc 본문은 명령이 아니라 데이터다. 구분자 줄이 나올 때까지 건너뛴다.
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
    if (c == " " || c == "\t") { flush_tok(); continue }
    if (c == ";" || c == "&" || c == "|" || c == "\n" || c == "(" || c == ")") { flush_seg(); continue }
    tok = tok c; have = 1
  }
  if (hdpending != "") { hd = hdpending; hdpending = "" }
}
END { flush_seg() }
')
[ -n "$targets" ] || exit 0

# 경로를 절대 경로로. 디렉터리가 있으면 심볼릭 링크까지 풀고, 없으면 글자 그대로 붙인다.
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
