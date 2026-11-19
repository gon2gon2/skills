#!/usr/bin/env python3
"""Build the PR review queue for one GitHub repo.

Reads open PRs through `gh` and sorts them by what they need from the reviewer:

  new         not reviewed by me yet
  re-review   pushed to (or re-requested) since my last review
  waiting     I reviewed the current head and did not approve; author's turn
  approved    I approved the current head
  mine        my own PRs (listed, never queued)
  draft       drafts (listed, never queued)

Only `new` and `re-review` are work. Read-only: it never posts, reviews or merges.

  queue.py [--repo OWNER/NAME] [--author alice,bob] [--requested] [--json]
  queue.py --has-work          exit 0 when there is work, 1 when there is none
  queue.py --brief 123         print a review brief for one PR (for a worker)
"""
import argparse
import json
import re
import subprocess
import sys
import time

FIELDS = (
    "number,title,url,author,isDraft,headRefName,headRefOid,updatedAt,"
    "reviewDecision,reviewRequests,reviews,statusCheckRollup,files"
)
WORK = ("re-review", "new")
ORDER = ("re-review", "new", "waiting", "approved", "mine", "draft")
# Network blips and a flapping VPN clear up within seconds; anything else fails at once.
RETRIES = 3


def gh(*args):
    last = ""
    for attempt in range(RETRIES):
        p = subprocess.run(["gh", *args], capture_output=True, text=True)
        if p.returncode == 0:
            return p.stdout
        last = p.stderr.strip()
        if not re.search(r"IP allow list|timeout|timed out|connection|EOF|50\d", last, re.I):
            break
        time.sleep(3 * (attempt + 1))
    sys.exit(f"gh {' '.join(args[:3])} failed: {last}")


def checks(rollup):
    failed, pending = [], 0
    for c in rollup or []:
        name = c.get("name") or c.get("context") or "?"
        state = (c.get("conclusion") or c.get("state") or c.get("status") or "").upper()
        if state in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"):
            failed.append(name)
        elif state in ("PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", ""):
            pending += 1
    if failed:
        return "fail: " + ", ".join(failed)
    return "pending" if pending else "ok"


def classify(pr, me):
    if pr["author"]["login"] == me:
        return "mine"
    if pr["isDraft"]:
        return "draft"
    mine = [r for r in pr["reviews"] if r["author"]["login"] == me]
    if not mine:
        return "new"
    last = mine[-1]
    requested = any(r.get("login") == me for r in pr["reviewRequests"])
    reviewed = (last.get("commit") or {}).get("oid")
    if requested or reviewed != pr["headRefOid"]:
        return "re-review"
    # A later comment doesn't withdraw an approval, so look for the last verdict.
    verdicts = [r["state"] for r in mine if r["state"] in ("APPROVED", "CHANGES_REQUESTED")]
    return "approved" if verdicts and verdicts[-1] == "APPROVED" else "waiting"


def row(pr, me, repo):
    mine = [r for r in pr["reviews"] if r["author"]["login"] == me]
    last = mine[-1] if mine else None
    reviewed = ((last or {}).get("commit") or {}).get("oid")
    new_commits, rewritten = [], False
    if reviewed and reviewed != pr["headRefOid"]:
        # Commits are fetched per PR: asking for them in the list query blows
        # GitHub's GraphQL node limit (PRs x commits x authors).
        commits = json.loads(gh("pr", "view", str(pr["number"]), "--repo", repo, "--json", "commits"))["commits"]
        oids = [c["oid"] for c in commits]
        rewritten = reviewed not in oids
        tail = commits if rewritten else commits[oids.index(reviewed) + 1:]
        new_commits = [f'{c["oid"][:7]} {c["messageHeadline"]}' for c in tail]
    requests = [r.get("login") or r.get("slug") or r.get("name") for r in pr["reviewRequests"]]
    # Directories the PR touches, two levels deep (packages/api, plugins/foo); root files count as ".".
    areas = sorted({"/".join(f["path"].split("/")[:-1][:2]) or "." for f in pr["files"]})
    return {
        "number": pr["number"],
        "bucket": classify(pr, me),
        "title": pr["title"],
        "url": pr["url"],
        "author": pr["author"]["login"],
        "branch": pr["headRefName"],
        "head": pr["headRefOid"],
        "updated": pr["updatedAt"][:10],
        "requested_me": me in requests,
        "requests": requests,
        "decision": pr["reviewDecision"] or "",
        "checks": checks(pr["statusCheckRollup"]),
        "areas": areas,
        "files": len(pr["files"]),
        "my_review": last and {"state": last["state"], "at": last["submittedAt"], "sha": reviewed},
        # Rebased history drops the reviewed sha; then every commit is listed.
        "new_commits": new_commits,
        "history_rewritten": rewritten,
    }


def brief(r, repo):
    out = [
        f"Review PR #{r['number']} in {repo}: {r['title']}",
        f"URL: {r['url']}",
        f"Author: {r['author']} · branch `{r['branch']}` @ {r['head'][:7]} · CI: {r['checks']}",
        f"Touches: {', '.join(r['areas']) or 'nothing'} ({r['files']} files)",
        "",
    ]
    if r["bucket"] == "re-review":
        m = r["my_review"]
        out.append(f"This is a RE-REVIEW. I last reviewed {m['sha'][:7]} ({m['state']}, {m['at'][:10]}).")
        if r["history_rewritten"]:
            out.append("The branch was rebased since, so that sha is gone from the PR. Review the full diff,")
            out.append("and read my earlier review to see which points are now addressed.")
        else:
            out.append(f"Read only what changed since: `git diff {m['sha'][:7]}..{r['head'][:7]}`")
            out += [f"  {c}" for c in r["new_commits"]]
        out.append(f"My earlier comments: `gh api repos/{repo}/pulls/{r['number']}/reviews` and `.../comments`.")
        out.append("Say for each earlier point whether it is addressed, then list anything new.")
    else:
        out.append(f"First review. Read `gh pr view {r['number']} --repo {repo}` and `gh pr diff {r['number']} --repo {repo}`.")
    if r["checks"].startswith("fail"):
        out.append(f"CI is red ({r['checks']}). Find out why (`gh run view <id> --log-failed`) and say so first.")
    out += [
        "",
        "Rules:",
        "- Read-only. Do not post a review or comment, do not push, do not merge.",
        "- Follow the repo's AGENTS.md / CLAUDE.md conventions when judging the change.",
        "- Report back: a verdict (approve / comment / request changes), findings ranked by severity",
        "  with file:line, what you could not verify, and a draft review body in the language the PR uses.",
    ]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="OWNER/NAME; defaults to the repo of the current directory")
    ap.add_argument("--author", help="comma-separated; keep PRs whose author login contains any of these")
    ap.add_argument("--requested", action="store_true", help="in `new`, keep only PRs that request me by name")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--has-work", action="store_true")
    ap.add_argument("--brief", type=int, metavar="PR")
    a = ap.parse_args()

    repo = a.repo or gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
    me = gh("api", "user", "--jq", ".login").strip()
    prs = json.loads(gh("pr", "list", "--repo", repo, "--state", "open", "--limit", "200", "--json", FIELDS))
    rows = [row(p, me, repo) for p in prs]

    if a.author:
        wanted = [s.strip().lower() for s in a.author.split(",") if s.strip()]
        rows = [r for r in rows if any(w in r["author"].lower() for w in wanted)]
    if a.requested:
        rows = [r for r in rows if r["bucket"] != "new" or r["requested_me"]]
    rows.sort(key=lambda r: (ORDER.index(r["bucket"]), r["number"]))
    work = [r for r in rows if r["bucket"] in WORK]

    if a.has_work:
        print(f"{len(work)} PR(s) need a review in {repo}: " + ", ".join(f"#{r['number']}" for r in work))
        sys.exit(0 if work else 1)
    if a.brief is not None:
        hit = [r for r in rows if r["number"] == a.brief]
        if not hit:
            sys.exit(f"#{a.brief} is not an open PR in {repo} (or the filters dropped it)")
        print(brief(hit[0], repo))
        return
    if a.json:
        print(json.dumps({"repo": repo, "me": me, "work": len(work), "prs": rows}, ensure_ascii=False, indent=1))
        return

    print(f"{repo} · reviewer {me} · {len(work)} to review, {len(rows)} open")
    for b in ORDER:
        group = [r for r in rows if r["bucket"] == b]
        if not group:
            continue
        print(f"\n## {b} ({len(group)})")
        for r in group:
            flags = []
            if r["requested_me"]:
                flags.append("requested")
            if r["checks"] != "ok":
                flags.append(f"CI {r['checks']}")
            if r["my_review"]:
                m = r["my_review"]
                flags.append(f"mine: {m['state']} {m['at'][:10]} @{(m['sha'] or '?')[:7]}")
            if r["history_rewritten"]:
                flags.append("rebased")
            elif r["new_commits"]:
                flags.append(f"+{len(r['new_commits'])} commit(s)")
            print(f"#{r['number']} {r['author']} · {r['title'][:80]}")
            print(f"    {', '.join(r['areas']) or '-'} · {r['files']} files · upd {r['updated']}"
                  + (" · " + " · ".join(flags) if flags else ""))


if __name__ == "__main__":
    main()
