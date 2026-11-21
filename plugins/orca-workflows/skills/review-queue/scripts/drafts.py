#!/usr/bin/env python3
"""Keep the review drafts of one GitHub repo between runs, and post the ones the user approved.

One record per PR, in <state>/<OWNER>__<NAME>/pr-<n>.json, with the review body beside it in
pr-<n>.md. <state> is --state-dir, then $REVIEW_QUEUE_STATE, then ~/.local/state/review-queue.

  drafts.py save 123 --sha <sha> --verdict approve|comment|request-changes --body-file <file>
                     [--summary <one line>] [--worktree <path>]
  drafts.py list [--status ready,stale,posted,merged,closed] [--unannounced] [--json]
  drafts.py post 123 [--as approve|comment|request-changes]
  drafts.py approve 123 [--as approve|comment|request-changes]
  drafts.py post --approved
  drafts.py notify --cmd "<command>"
  drafts.py forget 123 [124 ...]

A record's status:
  ready    not posted, and the PR head is still the sha that was reviewed
  stale    not posted, and the PR was pushed to since; the next run drafts it again
  posted   posted for the sha in the record
  merged, closed   the PR is no longer open; its review worktree can go

`post` is the only command that writes to GitHub. It posts the saved body as a review, and
refuses when the PR is not open or has moved past the reviewed sha. It never merges.

`approve` records the user's go-ahead without posting, for a program that takes the user's
answer somewhere else (a chat button). `post --approved` then posts every draft approved that
way. An agent never runs `approve` on its own judgment.

`notify` hands the new drafts, and the reviews posted since the last notice, to a command of
your choice: it writes them to <state>/<OWNER>__<NAME>/digest.json, runs `<command> <that path>`, and marks them
announced when the command exits 0.
"""
import argparse
import datetime
import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from queue import gh, load_drafts, state_dir  # noqa: E402  (this skill's queue.py, not the stdlib module)

VERDICTS = ("approve", "comment", "request-changes")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write(path, rec):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def record_path(folder, number):
    return os.path.join(folder, f"pr-{number}.json")


def need(drafts, number):
    if number not in drafts:
        sys.exit(f"no saved draft for #{number}")
    return drafts[number]


def pr_now(repo, number):
    return json.loads(gh("pr", "view", str(number), "--repo", repo, "--json", "state,headRefOid"))


def status(rec, pr):
    if pr["state"] != "OPEN":
        return pr["state"].lower()
    if rec.get("posted"):
        return "posted"
    return "ready" if rec["sha"] == pr["headRefOid"] else "stale"


def digest(repo, drafts):
    out = []
    for number, rec in sorted(drafts.items()):
        pr = pr_now(repo, number)
        try:
            with open(rec["body_file"]) as f:
                body = f.read()
        except OSError:
            body = ""
        out.append({**rec, "status": status(rec, pr), "head": pr["headRefOid"], "body": body})
    return out


def cmd_save(a, repo, folder, drafts):
    with open(a.body_file) as f:
        body = f.read()
    if not body.strip():
        sys.exit(f"{a.body_file} is empty")
    pr = json.loads(gh("pr", "view", str(a.number), "--repo", repo, "--json", "number,title,url,author,headRefOid"))
    old = drafts.get(a.number)
    body_file = os.path.join(folder, f"pr-{a.number}.md")
    os.makedirs(folder, exist_ok=True)
    with open(body_file, "w") as f:
        f.write(body)
    rec = {
        "repo": repo,
        "number": a.number,
        "title": pr["title"],
        "url": pr["url"],
        "author": pr["author"]["login"],
        "sha": a.sha,
        "kind": "re-review" if old else "new",
        "verdict": a.verdict,
        "summary": a.summary or "",
        "body_file": body_file,
        "worktree": a.worktree or (old or {}).get("worktree", ""),
        "drafted_at": now(),
        "posted": None,
        "announced": False,
    }
    write(record_path(folder, a.number), rec)
    note = "" if a.sha == pr["headRefOid"] else f" (the PR head is now {pr['headRefOid'][:7]}, so it is already stale)"
    print(f"saved draft for #{a.number} @ {a.sha[:7]}: {a.verdict}{note}")


def cmd_list(a, repo, folder, drafts):
    rows = digest(repo, drafts)
    if a.status:
        wanted = {s.strip() for s in a.status.split(",")}
        rows = [r for r in rows if r["status"] in wanted]
    if a.unannounced:
        rows = [r for r in rows if not r.get("announced")]
    if a.json:
        print(json.dumps({"repo": repo, "drafts": rows}, ensure_ascii=False, indent=1))
        return
    if not rows:
        print(f"no saved drafts for {repo}")
    for r in rows:
        print(f"#{r['number']} {r['status']} · {r['verdict']} @{r['sha'][:7]} · {r['author']} · {r['title'][:70]}")
        if r["summary"]:
            print(f"    {r['summary']}")
        print(f"    body: {r['body_file']}" + (f" · worktree: {r['worktree']}" if r["worktree"] else ""))


def post_one(repo, folder, rec, verdict):
    """Post one draft. Returns (ok, message)."""
    n = rec["number"]
    pr = pr_now(repo, n)
    st = status(rec, pr)
    if st == "posted":
        return False, f"#{n}: this draft was already posted ({rec['posted']['verdict']}, {rec['posted']['at']})"
    if st != "ready":
        why = "the PR was pushed to after the draft" if st == "stale" else f"the PR is {st}"
        return False, f"#{n}: not posted, {why} (drafted @ {rec['sha'][:7]}, head {pr['headRefOid'][:7]})"
    # One attempt only: a retry after a dropped connection could post the review twice.
    p = subprocess.run(["gh", "pr", "review", str(n), "--repo", repo, f"--{verdict}",
                        "--body-file", rec["body_file"]], capture_output=True, text=True)
    if p.returncode != 0:
        return False, (f"#{n}: gh pr review failed: {p.stderr.strip()}\n"
                       "Check the PR before trying again; the review may have gone through.")
    rec["posted"] = {"verdict": verdict, "at": now(), "sha": rec["sha"]}
    rec["announced"] = False
    write(record_path(folder, n), rec)
    return True, f"posted {verdict} on #{n} @ {rec['sha'][:7]}: {rec['url']}"


def cmd_post(a, repo, folder, drafts):
    if a.approved == (a.number is not None):
        sys.exit("give a PR number, or --approved to post every draft the user approved")
    if a.number is not None:
        rec = need(drafts, a.number)
        ok, msg = post_one(repo, folder, rec, a.verdict or rec["verdict"])
        if not ok:
            sys.exit(msg)
        print(msg)
        return
    todo = [r for _, r in sorted(drafts.items()) if r.get("approved") and not r.get("posted")]
    if not todo:
        print("no approved drafts to post")
    failed = 0
    for rec in todo:
        ok, msg = post_one(repo, folder, rec, rec["approved"]["verdict"])
        print(msg)
        failed += not ok
    sys.exit(1 if failed else 0)


def cmd_approve(a, repo, folder, drafts):
    rec = need(drafts, a.number)
    st = status(rec, pr_now(repo, a.number))
    if st != "ready":
        sys.exit(f"#{a.number}: not approved, the draft is {st}")
    rec["approved"] = {"verdict": a.verdict or rec["verdict"], "at": now()}
    write(record_path(folder, a.number), rec)
    print(f"#{a.number}: approved to post as {rec['approved']['verdict']} @ {rec['sha'][:7]}")


def cmd_notify(a, repo, folder, drafts):
    rows = [r for r in digest(repo, drafts) if not r.get("announced") and r["status"] in ("ready", "posted")]
    if not rows:
        print("nothing new to announce")
        return
    path = os.path.join(folder, "digest.json")
    write(path, {"repo": repo, "at": now(), "drafts": rows})
    p = subprocess.run([*shlex.split(a.cmd), path])
    if p.returncode != 0:
        sys.exit(f"notify command exited {p.returncode}; nothing was marked announced")
    for r in rows:
        rec = drafts[r["number"]]
        rec["announced"] = True
        write(record_path(folder, r["number"]), rec)
    print(f"announced {len(rows)} item(s): " + ", ".join(f"#{r['number']}" for r in rows))


def cmd_forget(a, repo, folder, drafts):
    for number in a.numbers:
        rec = need(drafts, number)
        for path in (record_path(folder, number), rec.get("body_file", "")):
            if path and os.path.dirname(os.path.abspath(path)) == os.path.abspath(folder) and os.path.exists(path):
                os.remove(path)
        print(f"forgot #{number}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", help="OWNER/NAME; defaults to the repo of the current directory")
    common.add_argument("--state-dir")
    sub = ap.add_subparsers(dest="action", required=True)

    s = sub.add_parser("save", parents=[common])
    s.add_argument("number", type=int)
    s.add_argument("--sha", required=True, help="the head sha that was reviewed")
    s.add_argument("--verdict", required=True, choices=VERDICTS)
    s.add_argument("--body-file", required=True)
    s.add_argument("--summary")
    s.add_argument("--worktree")

    s = sub.add_parser("list", parents=[common])
    s.add_argument("--status")
    s.add_argument("--unannounced", action="store_true")
    s.add_argument("--json", action="store_true")

    s = sub.add_parser("post", parents=[common])
    s.add_argument("number", type=int, nargs="?")
    s.add_argument("--as", dest="verdict", choices=VERDICTS)
    s.add_argument("--approved", action="store_true", help="post every draft marked by `approve`")

    s = sub.add_parser("approve", parents=[common])
    s.add_argument("number", type=int)
    s.add_argument("--as", dest="verdict", choices=VERDICTS)

    s = sub.add_parser("notify", parents=[common])
    s.add_argument("--cmd", required=True)

    s = sub.add_parser("forget", parents=[common])
    s.add_argument("numbers", type=int, nargs="+")

    a = ap.parse_args()
    repo = a.repo or gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
    folder = state_dir(repo, a.state_dir)
    drafts = load_drafts(repo, a.state_dir)
    {"save": cmd_save, "list": cmd_list, "post": cmd_post, "approve": cmd_approve, "notify": cmd_notify, "forget": cmd_forget}[a.action](a, repo, folder, drafts)


if __name__ == "__main__":
    main()
