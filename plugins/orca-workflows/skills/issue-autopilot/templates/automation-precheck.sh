#!/bin/bash
# Orca automation precheck: exit 0 only when a run can do useful work right now.
# Every skip prints one line, which Orca keeps in the run history.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GH="${AUTOMATION_GH:-gh}"   # point at scripts/gh when the repo pins a gh account
LOCK_TTL_S="${AUTOMATION_LOCK_TTL_S:-10800}"
# The git common dir is shared by every worktree of the repo, so runs in different worktrees see one lock.
LOCK="$(git rev-parse --path-format=absolute --git-common-dir)/automation.lock"

# GitHub reachable with the right account.
$GH api "repos/{owner}/{repo}" --jq .id >/dev/null 2>&1 || { echo "skip: GitHub unreachable"; exit 1; }

# Another run is still working. A lock older than the TTL belongs to a run that died; it no longer blocks.
if [ -f "$LOCK" ] && [ $(( $(date +%s) - $(cat "$LOCK") )) -lt "$LOCK_TTL_S" ]; then
  echo "skip: previous run still active"; exit 1
fi

# A PR is waiting for a human: wait for them instead of stacking work on an unreviewed change.
# Name them, so the run history says which PR to look at.
WAITING=$($GH pr list --label needs-human --state open --json number,url --jq '.[] | "#\(.number) \(.url)"')
if [ -n "$WAITING" ]; then
  echo "skip: PR needs a human: $(echo "$WAITING" | paste -sd ',' - | sed 's/,/, /g')"; exit 1
fi

# Something is ready to pick up. (Depends on: lines are checked by the run itself.)
READY=$($GH issue list --label auto --state open --json number,labels \
  --jq '[.[] | select(all(.labels[]; .name != "needs-human"))] | length')
[ "$READY" != "0" ] || { echo "skip: no open auto issues"; exit 1; }
echo "run: $READY candidate issue(s)"
