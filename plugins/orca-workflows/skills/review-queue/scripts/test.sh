#!/bin/sh
# Tests for queue.py and drafts.py against a fake `gh`. Run: sh test.sh
# The fake reads its PRs from $FAKE_GH/prs.json and logs every `gh pr review` to $FAKE_GH/posted.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
d = os.environ["FAKE_GH"]
prs = json.load(open(os.path.join(d, "prs.json")))
def field(name):
    return a[a.index(name) + 1]
if a[:2] == ["api", "user"]:
    print("me")
elif a[:2] == ["pr", "list"]:
    print(json.dumps([p for p in prs if p["state"] == "OPEN"]))
elif a[:2] == ["pr", "view"]:
    p = [p for p in prs if str(p["number"]) == a[2]][0]
    print(json.dumps({k: p[k] for k in field("--json").split(",")}))
elif a[:2] == ["pr", "review"]:
    if os.path.exists(os.path.join(d, "fail-review")):
        sys.exit("boom")
    with open(os.path.join(d, "posted"), "a") as f:
        f.write(" ".join(a[2:]) + "\n")
else:
    sys.exit("fake gh: unexpected " + " ".join(a))
PY
chmod +x "$tmp/bin/gh"
export FAKE_GH="$tmp" REVIEW_QUEUE_STATE="$tmp/state" PATH="$tmp/bin:$PATH"

# prs HEAD1 HEAD2 STATE2 : PR 1 has no review of mine, PR 2 was reviewed by me at aaa.
prs() {
  python3 - "$1" "$2" "$3" > "$tmp/prs.json" <<'PY'
import json, sys
h1, h2, s2 = sys.argv[1:]
def pr(n, head, state, reviews):
    return {"number": n, "title": f"PR {n}", "url": f"https://example.test/pr/{n}", "author": {"login": "ann"},
            "isDraft": False, "headRefName": f"b{n}", "headRefOid": head, "updatedAt": "2026-01-02T00:00:00Z",
            "reviewDecision": "", "reviewRequests": [], "reviews": reviews, "statusCheckRollup": [],
            "files": [{"path": "src/a.py"}], "state": state,
            "commits": [{"oid": o, "messageHeadline": "c " + o} for o in ("aaa", "bbb", "ccc", "ddd")]}
mine = [{"author": {"login": "me"}, "state": "COMMENTED", "submittedAt": "2026-01-01T00:00:00Z", "commit": {"oid": "aaa"}}]
print(json.dumps([pr(1, h1, "OPEN", []), pr(2, h2, s2, mine)]))
PY
}
Q="python3 $here/queue.py --repo o/r"
D="python3 $here/drafts.py"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $1"; }
has() { case "$2" in *"$3"*) ok ;; *) no "$1: expected '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1: did not expect '$3' in: $2" ;; *) ok ;; esac; }
code() { if [ "$2" = "$3" ]; then ok; else no "$1: exit $2, expected $3"; fi; }
echo "LGTM body" > "$tmp/body.md"

prs bbb aaa OPEN
out=$($Q); has "no drafts: header" "$out" "1 to review, 2 open"
has "no drafts: new" "$out" "## new (1)"; has "no drafts: waiting" "$out" "## waiting (1)"
$Q --has-work >/dev/null; code "has-work with a new PR" $? 0
has "first brief" "$($Q --brief 1)" "First review."

out=$($D save 1 --repo o/r --sha bbb --verdict approve --body-file "$tmp/body.md" --summary "fine" --worktree /wt/1)
has "save" "$out" "saved draft for #1 @ bbb: approve"
out=$($Q); has "drafted: header" "$out" "0 to review, 1 drafted and not posted"
has "drafted: flag" "$out" "draft: approve @bbb"
$Q --has-work >/dev/null; code "has-work with a current draft" $? 1
has "list ready" "$($D list --repo o/r)" "#1 ready"
has "list json body" "$($D list --repo o/r --json)" "LGTM body"

prs ccc aaa OPEN
out=$($Q); has "pushed after draft: queued" "$out" "1 to review"; has "pushed after draft: flag" "$out" "out of date"
out=$($Q --brief 1); has "re-review from draft" "$out" "I drafted a review of bbb"
has "draft diff range" "$out" "git diff bbb..ccc"; has "draft commits" "$out" "ccc c ccc"
has "draft replaces" "$out" "write one draft that replaces it"
has "list stale" "$($D list --repo o/r)" "#1 stale"
out=$($D post 1 --repo o/r 2>&1); code "post refuses a stale draft" $? 1
has "stale message" "$out" "pushed to after the draft"
[ -e "$tmp/posted" ] && no "stale draft was posted" || ok

echo "Second body" > "$tmp/body.md"
$D save 1 --repo o/r --sha ccc --verdict comment --body-file "$tmp/body.md" >/dev/null
has "second save keeps the worktree" "$($D list --repo o/r --json)" '"worktree": "/wt/1"'
has "second save is a re-review" "$($D list --repo o/r --json)" '"kind": "re-review"'

cat > "$tmp/notify.sh" <<'SH'
#!/bin/sh
cp "$1" "$FAKE_GH/got.json"; exit "${NOTIFY_RC:-0}"
SH
chmod +x "$tmp/notify.sh"
out=$(NOTIFY_RC=3 $D notify --repo o/r --cmd "$tmp/notify.sh" 2>&1); code "notify fails with its command" $? 1
has "failed notify leaves it unannounced" "$($D list --repo o/r --unannounced)" "#1 ready"
out=$($D notify --repo o/r --cmd "$tmp/notify.sh"); has "notify" "$out" "announced 1 item(s): #1"
has "digest file" "$(cat "$tmp/got.json")" "Second body"
has "notify twice" "$($D notify --repo o/r --cmd "$tmp/notify.sh")" "nothing new"

touch "$tmp/fail-review"
out=$($D post 1 --repo o/r 2>&1); code "post reports a gh failure" $? 1
has "still ready after a failed post" "$($D list --repo o/r)" "#1 ready"
rm "$tmp/fail-review"
out=$($D post 1 --repo o/r --as approve); has "post" "$out" "posted approve on #1 @ ccc"
has "gh call" "$(cat "$tmp/posted")" "1 --repo o/r --approve --body-file $tmp/state/o__r/pr-1.md"
out=$($D post 1 --repo o/r 2>&1); code "post twice refuses" $? 1; has "post twice message" "$out" "already posted"
has "a posted review is announced" "$($D notify --repo o/r --cmd "$tmp/notify.sh")" "announced 1 item(s): #1"
has "posted digest" "$(cat "$tmp/got.json")" '"status": "posted"'
[ "$(wc -l < "$tmp/posted" | tr -d ' ')" = 1 ] && ok || no "posted more than once"

# PR 2: reviewed on GitHub at aaa, then pushed to.
prs ccc ccc OPEN
out=$($Q --brief 2); has "re-review from GitHub" "$out" "I last reviewed aaa (COMMENTED"
has "github diff range" "$out" "git diff aaa..ccc"

# Approval recorded elsewhere, posted by the next run.
$D save 2 --repo o/r --sha ccc --verdict comment --body-file "$tmp/body.md" --worktree /wt/2 >/dev/null
has "nothing approved yet" "$($D post --approved --repo o/r)" "no approved drafts"
hasnt "has-work with nothing approved" "$($Q --has-work)" "wait to be posted"
has "approve" "$($D approve 2 --repo o/r --as request-changes)" "#2: approved to post as request-changes @ ccc"
out=$($Q --has-work); code "has-work with an approved draft" $? 0; has "has-work names approved" "$out" "wait to be posted: #2"
has "queue lists approved" "$($Q)" "## approved, not posted yet (1)"
has "post approved" "$($D post --approved --repo o/r)" "posted request-changes on #2 @ ccc"
has "gh call for approved" "$(tail -1 "$tmp/posted")" "2 --repo o/r --request-changes"
has "approved only once" "$($D post --approved --repo o/r)" "no approved drafts"
prs ddd ddd OPEN
$D save 1 --repo o/r --sha ccc --verdict comment --body-file "$tmp/body.md" >/dev/null
out=$($D approve 1 --repo o/r 2>&1); code "approve refuses a stale draft" $? 1; has "approve stale message" "$out" "the draft is stale"
out=$($D post --repo o/r 2>&1); code "post needs a number or --approved" $? 1
prs ccc ccc OPEN

# PR 2 merges after a draft was saved: the run has cleanup to do.
$D save 2 --repo o/r --sha ccc --verdict approve --body-file "$tmp/body.md" --worktree /wt/2 >/dev/null
prs ccc ccc MERGED
out=$($Q); has "gone section" "$out" "## reviewed, no longer open (1)"; has "gone worktree" "$out" "worktree: /wt/2"
out=$($Q --has-work); code "has-work with only cleanup" $? 0; has "has-work names it" "$out" "no longer open: #2"
has "list merged" "$($D list --repo o/r --status merged)" "#2 merged"
out=$($D post 2 --repo o/r 2>&1); code "post refuses a merged PR" $? 1
$D forget 2 --repo o/r >/dev/null
[ -e "$tmp/state/o__r/pr-2.json" ] || [ -e "$tmp/state/o__r/pr-2.md" ] && no "forget left files" || ok
hasnt "has-work after forget" "$($Q --has-work)" "no longer open"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
