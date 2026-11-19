#!/bin/sh
# Tests for orca-worktree-guard.sh and orca-worktree-sweep.sh. Puts a fake `orca` first on PATH, so real Orca
# state is never touched. The git repositories and stamp files they need are throwaway ones under a temp directory.
# Run: sh hooks/test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd -P)
guard=$here/orca-worktree-guard.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)

mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/repo-wt" "$tmp/with space" "$tmp/other" "$tmp/wt"
ln -s "$tmp/repo-wt" "$tmp/link-to-wt"

# Real repositories, so the guard can ask git which worktree a bare name means.
# repo owns repo-wt; a and b each own a linked worktree named feat.
mkrepo() { # mkrepo DIR WORKTREE
  git init -q "$1" &&
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init &&
    git -C "$1" worktree add -q "$2" >/dev/null 2>&1
}
mkrepo "$tmp/repo" "$tmp/repo-wt" && mkrepo "$tmp/a" "$tmp/wt/a/feat" && mkrepo "$tmp/b" "$tmp/wt/b/feat" ||
  { echo "cannot create the test repositories"; exit 1; }
mkdir -p "$tmp/repo/sub"

# Fake orca: reports that it manages repo (primary), repo-wt, "with space", and both worktrees named feat.
cat > "$tmp/bin/orca" <<JSON
#!/bin/sh
cat <<'OUT'
{"ok":true,"result":{"worktrees":[
 {"path":"$tmp/repo","hostId":"local","isMainWorktree":true},
 {"path":"$tmp/repo-wt","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/with space","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/wt/a/feat","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/wt/b/feat","hostId":"local","isMainWorktree":false},
 {"path":"$tmp/other","hostId":"ssh-box","isMainWorktree":false}
]}}
OUT
JSON
chmod +x "$tmp/bin/orca"
# Keep jq and git visible on the test PATH, with and without orca, wherever they are installed.
mkdir -p "$tmp/noorca"; ln -s "$(command -v jq)" "$tmp/noorca/jq"
ln -s "$(command -v git)" "$tmp/noorca/git"; ln -s "$(command -v git)" "$tmp/bin/git"

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
check "env -C value"             2 "env -C /tmp git worktree remove $tmp/repo-wt"
check "env -u value"             2 "env -u GIT_DIR git worktree remove $tmp/repo-wt"
check "sudo -p value"            2 "sudo -p pw: git worktree remove $tmp/repo-wt"
check "sudo --user value"        2 "sudo --user root git worktree remove $tmp/repo-wt"
check "sudo --group value"       2 "sudo --group wheel git worktree remove $tmp/repo-wt"
check "sudo --prompt value"      2 "sudo --prompt pw: git worktree remove $tmp/repo-wt"
check "git --git-dir= form"      2 "git --git-dir=$tmp/repo/.git worktree remove $tmp/repo-wt"
check "command before a comment" 2 "git worktree remove $tmp/repo-wt # cleanup"
check "# inside a word"          2 "echo a#b; git worktree remove $tmp/repo-wt"

# git finds a worktree by its last path component, so a bare name works from any directory.
check "basename-only target"     2 "git worktree remove repo-wt" "$tmp/repo/sub"
if grep -Fq "orca worktree rm --worktree \"path:$tmp/repo-wt\"" "$tmp/err"; then
  pass=$((pass + 1)); echo "ok   basename message names the managed path"
else fail=$((fail + 1)); echo "FAIL basename message names the managed path"; cat "$tmp/err"; fi

# Two repositories each own a managed worktree named feat. git picks the one in the repository it runs in.
check "bare name, repo a (-C)"   2 "git -C $tmp/a worktree remove feat"
if grep -Fq "\"path:$tmp/wt/a/feat\"" "$tmp/err" && ! grep -Fq "$tmp/wt/b/feat" "$tmp/err"; then
  pass=$((pass + 1)); echo "ok   bare name reports repo a's path"
else fail=$((fail + 1)); echo "FAIL bare name reports repo a's path"; cat "$tmp/err"; fi
check "bare name, repo b (cd)"   2 "cd $tmp/b && git worktree remove feat"
if grep -Fq "\"path:$tmp/wt/b/feat\"" "$tmp/err"; then
  pass=$((pass + 1)); echo "ok   bare name reports repo b's path"
else fail=$((fail + 1)); echo "FAIL bare name reports repo b's path"; cat "$tmp/err"; fi

# The inline bypass exempts only the removal it prefixes.
check "bypass value is not off"  2 "ORCA_WT_GUARD=offline git worktree remove $tmp/repo-wt"
check "bypass text in echo"      2 "echo ORCA_WT_GUARD=off; git worktree remove $tmp/repo-wt"
check "bypass text in a comment" 2 "git worktree remove $tmp/repo-wt # ORCA_WT_GUARD=off"
check "bypass on another command" 2 "ORCA_WT_GUARD=off git status; git worktree remove $tmp/repo-wt"
check "bypass covers one removal" 2 "ORCA_WT_GUARD=off git worktree remove $tmp/repo-wt; git worktree remove $tmp/wt/a/feat"
if grep -Fq "$tmp/wt/a/feat" "$tmp/err" && ! grep -Fq "path:$tmp/repo-wt" "$tmp/err"; then
  pass=$((pass + 1)); echo "ok   only the unexempted removal is reported"
else fail=$((fail + 1)); echo "FAIL only the unexempted removal is reported"; cat "$tmp/err"; fi

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
check "bare name of another repo" 0 "git worktree remove feat" "$tmp/repo/sub"
check "bare name, repo lacks it" 0 "git -C $tmp/a worktree remove repo-wt"
check "unknown bare name"        0 "git worktree remove not-orca" "$tmp/repo/sub"
check "bare name outside a repo" 0 "git worktree remove repo-wt" "$tmp/wt"
check "main worktree"            0 "git worktree remove $tmp/repo"
check "command -v lookup"        0 "command -v git worktree remove $tmp/repo-wt"
check "command -V lookup"        0 "command -V git worktree remove $tmp/repo-wt"
check "env-wrapped inline bypass" 0 "env ORCA_WT_GUARD=off git worktree remove $tmp/repo-wt"
check "here-string is not heredoc" 2 "cat <<< hi; git worktree remove $tmp/repo-wt"
check "inline bypass"            0 "ORCA_WT_GUARD=off git worktree remove $tmp/repo-wt"
check "orca not installed"       0 "git worktree remove $tmp/repo-wt" "$tmp/repo" "$tmp/noorca"

payload=$(jq -nc --arg c "git worktree remove $tmp/repo-wt" '{tool_input:{command:$c}}')
printf '%s' "$payload" | ORCA_WT_GUARD=off PATH="$tmp/bin:/usr/bin:/bin" sh "$guard" >/dev/null 2>&1
if [ $? = 0 ]; then pass=$((pass + 1)); echo "ok   env bypass"; else fail=$((fail + 1)); echo "FAIL env bypass"; fi

printf 'not json' | PATH="$tmp/bin:/usr/bin:/bin" sh "$guard" >/dev/null 2>&1
if [ $? = 0 ]; then pass=$((pass + 1)); echo "ok   malformed payload"; else fail=$((fail + 1)); echo "FAIL malformed payload"; fi

# ---- orca-worktree-sweep.sh ----
sweep=$here/orca-worktree-sweep.sh

# Fake orca for the sweep: answers only `worktree ps` and logs every call, so the tests can show that the
# hook runs nothing else. r1 has repo as primary with three local worktrees (one folder is gone) and one on
# another host; r2 has a primary and no other worktree; r3 has a primary and one worktree.
mkswbin() { # mkswbin DIR TRUNCATED
  mkdir -p "$1"
  cat > "$1/orca" <<JSON
#!/bin/sh
echo "\$*" >> "$tmp/orca-calls"
[ "\$1 \$2" = "worktree ps" ] || exit 1
cat <<'OUT'
{"ok":true,"result":{"truncated":$2,"worktrees":[
 {"repoId":"r1","path":"$tmp/repo","hostId":"local","isMainWorktree":true},
 {"repoId":"r1","path":"$tmp/repo-wt","hostId":"local","isMainWorktree":false},
 {"repoId":"r1","path":"$tmp/with space","hostId":"local","isMainWorktree":false},
 {"repoId":"r1","path":"$tmp/gone","hostId":"local","isMainWorktree":false},
 {"repoId":"r1","path":"$tmp/other","hostId":"ssh-box","isMainWorktree":false},
 {"repoId":"r2","path":"$tmp/a","hostId":"local","isMainWorktree":true},
 {"repoId":"r3","path":"$tmp/b","hostId":"local","isMainWorktree":true},
 {"repoId":"r3","path":"$tmp/wt/b/feat","hostId":"local","isMainWorktree":false},
 {"repoId":null,"path":"$tmp/wt","hostId":"local","isMainWorktree":false}
]}}
OUT
JSON
  chmod +x "$1/orca"; ln -s "$(command -v jq)" "$1/jq"
}
mkswbin "$tmp/swbin" false
mkswbin "$tmp/swbin-trunc" true
# An orca that does not answer, and one that answers with something that is not JSON.
mkdir -p "$tmp/swbin-down" "$tmp/swbin-junk" "$tmp/empty"
printf '#!/bin/sh\nexit 1\n' > "$tmp/swbin-down/orca"; printf '#!/bin/sh\necho not json\n' > "$tmp/swbin-junk/orca"
chmod +x "$tmp/swbin-down/orca" "$tmp/swbin-junk/orca"
ln -s "$(command -v jq)" "$tmp/swbin-down/jq"; ln -s "$(command -v jq)" "$tmp/swbin-junk/jq"

states=0
# sweep_run CWD [SOURCE] [PATH] [STATE_DIR]: stdout goes to $tmp/out, the exit code to $got.
# Each run gets a fresh state directory unless one is given.
sweep_run() {
  if [ -n "${4-}" ]; then st=$4; else states=$((states + 1)); st=$tmp/state$states; fi
  jq -nc --arg d "$1" --arg s "${2:-startup}" '{hook_event_name:"SessionStart",cwd:$d,source:$s}' |
    PATH="${3:-$tmp/swbin:/usr/bin:/bin}" XDG_STATE_HOME="$st" /bin/sh "$sweep" >"$tmp/out" 2>"$tmp/err"
  got=$?
}
# expect NAME TEXT: exit 0, and stdout is one line containing TEXT, or empty when TEXT is "".
expect() {
  if [ "$got" = 0 ] && { if [ -z "$2" ]; then [ ! -s "$tmp/out" ]; else
      [ "$(wc -l < "$tmp/out" | tr -d ' ')" = 1 ] && grep -Fq -- "$2" "$tmp/out"; fi; }; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$1"
  else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$1" "$got"; sed 's/^/     /' "$tmp/out" "$tmp/err"; fi
}

sweep_run "$tmp/repo";                 expect "sweep: primary with worktrees" "non-primary worktrees on this machine: 3, missing folders: 1."
expect "sweep: names the primary"      "cleanup pass due for $tmp/repo:"
sweep_run "$tmp/b";                    expect "sweep: no folder missing" "worktrees on this machine: 1, missing folders: 0."
sweep_run "$tmp/repo/sub";             expect "sweep: folder inside the primary" "cleanup pass due for $tmp/repo:"
sweep_run "$tmp/a";                    expect "sweep: primary with no worktrees" ""
sweep_run "$tmp/repo-wt";              expect "sweep: worker worktree" ""
sweep_run "$tmp/link-to-wt";           expect "sweep: symlink to a worker worktree" ""
sweep_run "$tmp/other";                expect "sweep: path Orca lists on another host" ""
sweep_run "$tmp/wt";                   expect "sweep: folder with no repository" ""
sweep_run "$tmp/not-orca";             expect "sweep: outside Orca" ""
sweep_run "$tmp/repo" startup "$tmp/swbin-trunc:/usr/bin:/bin"; expect "sweep: truncated list is flagged" "list was truncated"
sweep_run "$tmp/repo" resume;          expect "sweep: resumed session" "cleanup pass due"

# Fails open: nothing printed, exit 0.
sweep_run "$tmp/repo" startup "$tmp/empty";                    expect "sweep: jq not installed" ""
sweep_run "$tmp/repo" startup "$tmp/noorca:/usr/bin:/bin";     expect "sweep: orca not installed" ""
sweep_run "$tmp/repo" startup "$tmp/swbin-down:/usr/bin:/bin"; expect "sweep: orca does not answer" ""
sweep_run "$tmp/repo" startup "$tmp/swbin-junk:/usr/bin:/bin"; expect "sweep: orca output is not JSON" ""
printf 'not json' | PATH="$tmp/swbin:/usr/bin:/bin" XDG_STATE_HOME="$tmp/state-bad" /bin/sh "$sweep" >"$tmp/out" 2>"$tmp/err"
got=$?;                                expect "sweep: malformed payload" ""
jq -nc --arg d "$tmp/repo" '{cwd:$d}' | ORCA_WT_SWEEP=off PATH="$tmp/swbin:/usr/bin:/bin" XDG_STATE_HOME="$tmp/state-off" \
  /bin/sh "$sweep" >"$tmp/out" 2>"$tmp/err"
got=$?;                                expect "sweep: env bypass" ""

# No cwd in the payload: falls back to the directory the hook runs in.
(cd "$tmp/repo" && printf '{}' | PATH="$tmp/swbin:/usr/bin:/bin" XDG_STATE_HOME="$tmp/state-pwd" /bin/sh "$sweep" >"$tmp/out" 2>"$tmp/err")
got=$?;                                expect "sweep: payload without cwd" "cleanup pass due for $tmp/repo:"

# At most one notice per repository every 24 hours.
T=$tmp/state-throttle
sweep_run "$tmp/repo" startup "" "$T"; expect "sweep: first notice" "cleanup pass due"
if [ -s "$T/orca-worktree-sweep/r1.stamp" ]; then pass=$((pass + 1)); echo "ok   sweep: stamp file written"
else fail=$((fail + 1)); echo "FAIL sweep: stamp file written"; fi
sweep_run "$tmp/repo" startup "" "$T"; expect "sweep: second run within 24 hours" ""
sweep_run "$tmp/repo/sub" resume "" "$T"; expect "sweep: same repository, other folder" ""
sweep_run "$tmp/b" startup "" "$T";    expect "sweep: another repository still notifies" "cleanup pass due for $tmp/b:"
echo $(($(date +%s) - 86100)) > "$T/orca-worktree-sweep/r1.stamp"
sweep_run "$tmp/repo" startup "" "$T"; expect "sweep: stamp 23h55m old" ""
echo $(($(date +%s) - 86500)) > "$T/orca-worktree-sweep/r1.stamp"
sweep_run "$tmp/repo" startup "" "$T"; expect "sweep: stamp older than 24 hours" "cleanup pass due"
sweep_run "$tmp/repo" startup "" "$T"; expect "sweep: stamp renewed by that notice" ""
echo garbage > "$T/orca-worktree-sweep/r1.stamp"
sweep_run "$tmp/repo" startup "" "$T"; expect "sweep: unreadable stamp counts as none" "cleanup pass due"

# A run that prints nothing leaves no stamp behind.
C=$tmp/state-compact
sweep_run "$tmp/repo" compact "" "$C"; expect "sweep: after compaction" ""
sweep_run "$tmp/repo" startup "" "$C"; expect "sweep: compaction did not use up the notice" "cleanup pass due"
N=$tmp/state-none
sweep_run "$tmp/a" startup "" "$N"; sweep_run "$tmp/repo-wt" startup "" "$N"
if [ ! -e "$N/orca-worktree-sweep" ]; then pass=$((pass + 1)); echo "ok   sweep: silent runs write no stamp"
else fail=$((fail + 1)); echo "FAIL sweep: silent runs write no stamp"; fi

# If the stamp cannot be written, stay silent instead of repeating in every session.
: > "$tmp/state-file"
sweep_run "$tmp/repo" startup "" "$tmp/state-file"; expect "sweep: stamp cannot be written" ""

# Read-only: the only orca command it ever ran is the listing, and the worktree folders are still there.
if [ -s "$tmp/orca-calls" ] && ! grep -Fvxq -- "worktree ps --limit 10000 --json" "$tmp/orca-calls"; then
  pass=$((pass + 1)); echo "ok   sweep: runs only orca worktree ps"
else fail=$((fail + 1)); echo "FAIL sweep: runs only orca worktree ps"; sort -u "$tmp/orca-calls" 2>/dev/null; fi
if [ -d "$tmp/repo-wt" ] && [ -d "$tmp/with space" ] && [ -d "$tmp/wt/b/feat" ]; then
  pass=$((pass + 1)); echo "ok   sweep: worktree folders untouched"
else fail=$((fail + 1)); echo "FAIL sweep: worktree folders untouched"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
