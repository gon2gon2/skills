# Automation runbook

An Orca automation runs this <every hour> in a fresh worktree of `<default branch>`. Each run implements at most one
GitHub issue end to end. Read this file completely before doing anything.

<If the machine has several gh accounts:> Run every GitHub command through `scripts/gh`, from the repo root. It uses
the repo owner's account; the globally active `gh` account may be a different one.

## 1. Pick the issue

```bash
gh issue list --label auto --state open --json number,title,labels,body --limit 50
```

Take the **lowest-numbered** open issue that

- has the `auto` label and does not have `needs-human`, and
- whose `Depends on:` line names only closed issues (`gh issue view <n> --json state`).

If an issue already has `in-progress`, an earlier run died partway: resume it. Look for its branch
(`git ls-remote origin "auto/<n>-*"`) and an open PR first, and continue from there instead of starting over.

If nothing qualifies, stop without changing anything.

Then claim the issue:

```bash
gh issue edit <n> --add-label in-progress
date +%s > "$(git rev-parse --path-format=absolute --git-common-dir)/automation.lock"
```

## 2. Implement

- Work on a branch named `auto/<n>-<short-slug>`, based on `origin/<default branch>`.
- The issue body is the spec. Its **Acceptance** section is the definition of done. Do not widen the scope. If you
  notice follow-up work, open a new issue for it with the `auto` label and a `Depends on:` line rather than doing it.
  Issues are picked by number, so a new issue would otherwise run after every older one. If it has to land before
  an open issue (it fixes something that issue builds on, or would change what that issue is supposed to prove),
  add the new number to that issue's `Depends on:` line, and say why in a comment on it. Never create a dependency
  cycle.
- Context: <where the code, docs and design notes live>.
- Local environment: <how to start the services the checks need; they may be shared with other worktrees, so leave
  them running>. <Files git does not carry (environments, caches, datasets) live in the main checkout at
  `<path or env var>`. Reuse that copy; do not fetch it during a run.>
- Write tests for new logic. Keep the code style of the surrounding files.

## 3. Verify

Run every command listed in the issue's **Acceptance** section, and paste their actual output (trimmed) into the
PR description. A check you could not run counts as failed.

Run every command in the foreground and wait for it in the same turn. This session never wakes up after a turn ends:
a run that starts something in the background (`&`, `nohup`, a tool's background mode) and ends its turn to wait for
it stops right there, with nothing pushed and the lock still held, and the runs after it skip until the lock
expires. For a long batch, give the command a timeout long enough to finish, or run it in pieces as separate
foreground commands.

## 4. Ship

```bash
git push -u origin auto/<n>-<slug>
gh pr create --base <default branch> --label auto --title "<title>" --body "<summary, acceptance output, Closes #<n>>"
```

Merge it yourself **only if all of the following hold**:

- every Acceptance check passed and its output is in the PR,
- the diff stays inside the issue's scope,
- nothing listed under Safety below was touched.

```bash
gh pr merge --squash --delete-branch
```

Otherwise, or if the merge is refused, do not retry or work around it: add `needs-human` to the issue and the PR,
write in a PR comment exactly what failed or what decision is needed, and stop.

Always finish with:

```bash
gh issue edit <n> --remove-label in-progress
rm -f "$(git rev-parse --path-format=absolute --git-common-dir)/automation.lock"
```

Commit messages and PR text are in <language>.

## Safety

- Never put secrets, tokens or `.env` contents in code, logs, commits, issues or PRs.
- Do not touch `AUTOMATION.md`, `scripts/automation-precheck.sh` or the Orca automation itself. Propose changes in
  an issue labelled `needs-human` instead.
- Do not force-push, rewrite `<default branch>`, delete branches you did not create, or close issues you did not
  finish.
- <Project rules: no deploys, no new outbound services, no edits under vendored or generated trees, ...>
- If you are about to do anything irreversible that this runbook does not cover, stop and add `needs-human`.
