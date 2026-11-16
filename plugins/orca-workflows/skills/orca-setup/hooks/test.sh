#!/bin/sh
# Tests for orca-worktree-guard.sh. Puts a fake `orca` first on PATH, so real Orca state is never touched.
# Run: sh hooks/test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd -P)
guard=$here/orca-worktree-guard.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)

mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/repo-wt" "$tmp/with space" "$tmp/other" \
  "$tmp/repo/sub" "$tmp/a/dup" "$tmp/b/dup"
ln -s "$tmp/repo-wt" "$tmp/link-to-wt"

# Fake orca: reports that it manages repo (primary), repo-wt, "with space", and two worktrees both named dup.
cat > "$tmp/bin/orca" <<JSON
#!/bin/sh
cat <<'OUT'
{"ok":true,"result":{"worktrees":[
 {"path":"$tmp/repo","hostId":"local","isMainWorktree":true},
 {"path":"$tmp/repo-wt","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/with space","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/a/dup","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/b/dup","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/other","hostId":"ssh-box","isMainWorktree":false}
]}}
OUT
JSON
chmod +x "$tmp/bin/orca"
# Keep jq visible on a PATH that has no orca.
mkdir -p "$tmp/noorca"; ln -s "$(command -v jq)" "$tmp/noorca/jq"

pass=0 fail=0
# check NAME EXPECTED_EXIT COMMAND [CWD] [PATH_PREFIX]
check() {
  name=$1 want=$2 command=$3 cwd=${4:-$tmp/repo} pre=${5:-$tmp/bin}
  payload=$(jq -nc --arg c "$command" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  printf '%s' "$payload" | PATH="$pre:/usr/bin:/bin" sh "$guard" >/dev/null 2>"$tmp/err"
  got=$?
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s (want %s, got %s)\n' "$name" "$want" "$got"; sed 's/^/     /' "$tmp/err"; fi
}

# Must block
check "absolute path"            2 "git worktree remove $tmp/repo-wt"
check "--force flag"             2 "git worktree remove --force $tmp/repo-wt"
check "flag after path"          2 "git worktree remove $tmp/repo-wt -f"
check "relative to cwd"          2 "git worktree remove ../repo-wt"
check "cd then remove"           2 "cd $tmp && git worktree remove repo-wt"
check "git -C"                   2 "git -C $tmp worktree remove repo-wt"
check "quoted path with space"   2 "git worktree remove \"$tmp/with space\""
check "symlink to worktree"      2 "git worktree remove $tmp/link-to-wt"
check "after other command"      2 "git status; git worktree remove $tmp/repo-wt"
check "env assignment prefix"    2 "GIT_TRACE=1 git worktree remove $tmp/repo-wt"
check "integration probe (-C missing)" 2 "git -C /nonexistent-orca-guard-check worktree remove $tmp/repo-wt"
check "command wrapper"          2 "command git worktree remove $tmp/repo-wt"
check "env wrapper"              2 "env GIT_TRACE=1 git worktree remove $tmp/repo-wt"
check "sudo wrapper"             2 "sudo -n git worktree remove $tmp/repo-wt"
check "after heredoc"            2 "cat <<X
hello
X
git worktree remove $tmp/repo-wt"
check "git global -c option"     2 "git -c core.quotepath=off worktree remove $tmp/repo-wt"
check "inside if/then"           2 "if true; then git worktree remove $tmp/repo-wt; fi"
check "inside else"              2 "if false; then :; else git worktree remove $tmp/repo-wt; fi"
check "elif condition"           2 "if false; then :; elif git worktree remove $tmp/repo-wt; then :; fi"
check "after elif/then"          2 "if false; then :; elif true; then git worktree remove $tmp/repo-wt; fi"
check "if condition"             2 "if git worktree remove $tmp/repo-wt; then :; fi"
check "brace group"              2 "{ git worktree remove $tmp/repo-wt; }"
check "for/do loop"              2 "for x in 1; do git worktree remove $tmp/repo-wt; done"
check "while condition"          2 "while git worktree remove $tmp/repo-wt; do break; done"
check "negated with !"           2 "! git worktree remove $tmp/repo-wt"
check "sudo -u value"            2 "sudo -u root git worktree remove $tmp/repo-wt"
check "sudo -g value"            2 "sudo -g wheel git worktree remove $tmp/repo-wt"
check "git --git-dir value"      2 "git --git-dir $tmp/repo/.git worktree remove $tmp/repo-wt"
check "git --work-tree value"    2 "git --work-tree $tmp/repo worktree remove $tmp/repo-wt"
check "git --namespace value"    2 "git --namespace ns worktree remove $tmp/repo-wt"
check "git --git-dir= form"      2 "git --git-dir=$tmp/repo/.git worktree remove $tmp/repo-wt"
check "command before a comment" 2 "git worktree remove $tmp/repo-wt # cleanup"
check "# inside a word"          2 "echo a#b; git worktree remove $tmp/repo-wt"

# git finds a worktree by its last path component, so a bare name works from any directory.
check "basename-only target"     2 "git worktree remove repo-wt" "$tmp/repo/sub"
if grep -Fq "orca worktree rm --worktree \"path:$tmp/repo-wt\"" "$tmp/err"; then
  pass=$((pass + 1)); echo "ok   basename message names the managed path"
else fail=$((fail + 1)); echo "FAIL basename message names the managed path"; cat "$tmp/err"; fi

# Payload whose command is an array, as in Codex
payload=$(jq -nc --arg c "git worktree remove $tmp/repo-wt" --arg d "$tmp/repo" '{tool_input:{command:["bash","-lc",$c]},cwd:$d}')
printf '%s' "$payload" | PATH="$tmp/bin:/usr/bin:/bin" sh "$guard" >/dev/null 2>&1
if [ $? = 2 ]; then pass=$((pass + 1)); echo "ok   codex array command"; else fail=$((fail + 1)); echo "FAIL codex array command"; fi

# The block message includes the orca worktree rm command
check "message names orca rm"    2 "git worktree remove $tmp/repo-wt"
if grep -Fq "orca worktree rm --worktree \"path:$tmp/repo-wt\"" "$tmp/err"; then
  pass=$((pass + 1)); echo "ok   message content"
else fail=$((fail + 1)); echo "FAIL message content"; cat "$tmp/err"; fi

# Must pass
check "unregistered path"        0 "git worktree remove $tmp/not-orca"
check "other host's path"        0 "git worktree remove $tmp/other"
check "unrelated command"        0 "ls -la"
check "git worktree list"        0 "git worktree list"
check "git worktree add"         0 "git worktree add $tmp/new"
check "string inside echo"       0 "echo 'git worktree remove $tmp/repo-wt'"
check "inside heredoc"           0 "cat <<X
git worktree remove $tmp/repo-wt
X"
check "inside quoted heredoc"    0 "cat > notes.md <<'X'
git worktree remove $tmp/repo-wt
X"
check "inside <<- heredoc"       0 "cat <<-X
	git worktree remove $tmp/repo-wt
	X"
check "inside a comment"         0 "git status # then; git worktree remove $tmp/repo-wt"
check "comment on its own line"  0 "# git worktree remove $tmp/repo-wt
git status"
check "a#b is one token"         0 "git worktree remove $tmp/repo-wt#x"
check "ambiguous basename"       0 "git worktree remove dup" "$tmp/repo/sub"
check "unknown basename"         0 "git worktree remove not-orca" "$tmp/repo/sub"
check "here-string is not heredoc" 2 "cat <<< hi; git worktree remove $tmp/repo-wt"
check "inline bypass"            0 "ORCA_WT_GUARD=off git worktree remove $tmp/repo-wt"
check "orca not installed"       0 "git worktree remove $tmp/repo-wt" "$tmp/repo" "$tmp/noorca"

payload=$(jq -nc --arg c "git worktree remove $tmp/repo-wt" '{tool_input:{command:$c}}')
printf '%s' "$payload" | ORCA_WT_GUARD=off PATH="$tmp/bin:/usr/bin:/bin" sh "$guard" >/dev/null 2>&1
if [ $? = 0 ]; then pass=$((pass + 1)); echo "ok   env bypass"; else fail=$((fail + 1)); echo "FAIL env bypass"; fi

printf 'not json' | PATH="$tmp/bin:/usr/bin:/bin" sh "$guard" >/dev/null 2>&1
if [ $? = 0 ]; then pass=$((pass + 1)); echo "ok   malformed payload"; else fail=$((fail + 1)); echo "FAIL malformed payload"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
