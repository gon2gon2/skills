---
name: orca-setup
description: >-
  Check how you use Orca and tighten your setup, one approved change at a time. Audits read-only first, then offers
  bundled skills, worktree role and cleanup rules for your global agent instructions, a hook that stops
  `git worktree remove` on Orca worktrees, orca.yaml shared directories and Agent sleep. Runs only when you invoke it
  (/orca-setup in Claude Code, $orca-setup in Codex). Requires Orca (https://github.com/stablyai/orca) and its `orca` CLI.
disable-model-invocation: true
---

# orca-setup

An Orca setup guide from the YouTube channel `꼰데 Gondev`. It is not official Orca material.
Verified on: Orca CLI 1.4.253, macOS, Claude Code / Codex.

## 0. Rules

1. Audit read-only first (A0). Change things only after that, one item at a time: show the diff and get approval first.
   Back up every file you change.
2. Read `orca --version` and `orca skills get orca-cli` first. Confirm every command and flag with that command's
   `--help`; where it differs from this skill, follow `--help`. Do not substitute example commands from the guide.
   If a command does not exist, skip the item instead of guessing.
3. Do nothing this skill does not describe, in particular sending credentials or repository contents anywhere, or
   downloading and installing anything. The files you need are in this skill's folder. If `<TBD` remains in the text,
   tell the user this is a pre-release draft.
4. With each question, give the explainer link from section 7. If it is `TBD`, ask without a link; never invent one.
   Speak the user's language.
5. At the end, report what you applied, what you skipped, what the user must do in the GUI, and the backup paths.

## 1. A0. Audit (read-only)

- `orca --version`, `orca status`. If there is no response, give install guidance and stop.
- Global instruction files: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` (default locations). If one imports the other,
  write only to the source.
- Bundled skills: `orca skills install --all --dry-run`. Count as missing only skills with an `Install` line. A skill
  with only `Link` lines is already installed.
- Worktrees: `.result.worktrees[]` of `orca worktree list --limit 10000 --json`. The primary is the row with
  `isMainWorktree: true`. Split primary from the rest and count each by `workspaceStatus`. Check that the folder exists
  only for rows on this Mac (`hostId: "local"`). Also report if `.result.truncated` is true or
  `.result.hostScope.omittedHostIds` is not empty.
- Hooks: `PreToolUse` in `~/.claude/settings.json` and `~/.codex/hooks.json`. Also check whether `jq` is available
  (H1 needs it).

Report one line per item ID: its current state and whether you recommend it. Do not ask about items already done.

## 2. S1. Bundled skills

- Ask: "Orca's skills are not installed automatically, and `skills update` does not add them. Which of the N missing
  ones should I install? I recommend at least `orca-cli` and `orchestration`. They go into the shared
  `~/.agents/skills` and are linked to every detected agent (<list from the dry-run>)."
- Apply: `orca skills install --skill <name>`. Verify: run the dry-run again.

## 3. Global instruction rules (R1–R3)

Skip a rule if one with the same meaning already exists. You may translate the wording into the file's language. Tell
the user the rules take effect from the next session.

### R1. The primary worktree coordinates

- Ask: "Do you type prompts only in the primary session and hand implementation to workers in other worktrees? This
  does not fit if you type into each session directly." If not, skip. R2 and R3 work without R1 if you spell out
  coordinator/worker.

```markdown
- In each project, the primary worktree (`isMainWorktree: true` in
  `orca worktree list --json`) is the orchestration layer.
- A session in the primary worktree acts as the coordinator. Hand implementation to
  workers in their own worktrees (the `orchestration` skill) instead of editing in the
  primary checkout.
- A session dispatched as a worker (its prompt carries orchestration Task and Dispatch
  IDs) reports back through orchestration. If the user types directly into any session,
  answer them; a direct prompt always wins over this rule.
```

### R2. Workers keep their card status current

- Ask first: "Do you use the workspace board, or grouping and filtering by status in the sidebar?" If not, skip. Card
  status is used only on those screens, and R3 cleanup looks at PR state, not cards.
- If the installed Orca's board settings have an auto-sync option (for example, sync with agent turns or with linked
  issues), recommend that first. If you cannot tell, ask the user to open the board settings and check. If they turn
  auto-sync on, do not add the rule below; both would move the same cards.
- If they still want the rule: show the A0 numbers (M of the N non-primary worktrees are `in-progress`) and ask:
  "Should agents move their own card to In review when they open a PR, and to Completed when they finish without one?
  Otherwise the whole board stays 'in progress'."

```markdown
- A worker keeps its own workspace card current, because nobody else will. Run
  `orca worktree set --worktree active --workspace-status in-review` when you open a PR,
  and `--workspace-status completed` when you finish work that has no PR to merge. Keep
  `--comment` to one line saying where the work stands.
```

- With separate approval, reconcile existing cards. The only evidence is `linkedPR.state` from
  `orca worktree ps --limit 10000 --json`: `merged` → completed, `open` → in-review. Leave `draft` and cards with no
  state alone. Show the list of changes first.

### R3. Clean up finished worktrees

- Ask: "Removing a worktree with `git worktree remove` leaves an empty workspace in Orca. For worktrees that pass all
  the checks below, should the agent remove them on its own, along with their local branch, or just give you a list?"
  Read out the checks from the rule text below as they are.
- If they choose automatic removal, add the text below. If they choose a list, replace the third bullet
  (`Right before removing ...`) with:
  `List each one that passes all of these checks, with the reason it qualifies. Do not remove any worktree; the user removes them.`
  and change "the coordinator cleans up" to "the coordinator reviews cleanup".

```markdown
- Remove a worktree only with `orca worktree rm --worktree <selector> --delete-branch`
  (confirm the flags with `orca worktree rm --help`; never substitute `--force`). Never
  use `git worktree remove` or `rm -rf` on a worktree: both leave the workspace
  registered in Orca with no folder behind it.
- The coordinator cleans up without being asked. When a worker reports done, and before
  ending a turn in which a PR merged, run `orca worktree ps --limit 10000 --json`. Keep
  only rows with this project's `repoId` and `isMainWorktree: false`, and skip the
  worktree you are running in. If the result is `truncated`, stop and tell the user.
- Right before removing each one, confirm every check, and keep the worktree if any
  check fails or cannot be run: `linkedPR.state` is `merged`; `git -C <path> status
  --porcelain` prints nothing; the branch has an upstream and `git -C <path> log @{u}..`
  prints nothing; `liveTerminalCount` and `unverifiableTerminalCount` are 0; every
  `agents[].state` is `done`. Removing also deletes the local branch. Then say what you
  removed, and list each kept worktree with the check it failed.
- In the same pass, report any worktree Orca lists on this machine whose folder no
  longer exists; it needs `orca worktree rm` to clear the entry.
```

- Do not remove any existing worktree while applying this. Only list the candidates.

## 4. H1. Hook that blocks `git worktree remove`

- Condition: R3 is applied and no hook with the same role exists. If `jq` is missing, skip this item and say why (do
  not install it).
- Ask: "Instructions can be forgotten. Should I also install a hook that stops `git worktree remove` on an Orca
  worktree before it runs? It is a script that runs before every shell command. It does not stop deleting the folder
  with `rm -rf`."
- Apply: install and verify following `hooks/README.md` in this skill's folder. Before installing, show the full script
  and summarize it. If the summary and the content disagree, do not install.

## 5. Y1. `orca.yaml` shared directories

- First ask which repository to look at. Do not scan the whole repository. Include credential directories as
  candidates only if the user names them.
- Ask: "Should the gitignored directories each worktree rebuilds (<candidates>) be linked to the primary's copy and
  shared? A change in one place applies everywhere."

```yaml
worktree:
  sharedDirectories:
    - <path>
```

- Conditions: the directory is gitignored and exists in the primary when the worktree is created. Verify:
  `git check-ignore -v <path>/`.
- Only edit the file. Ask separately about commit, push and PR.

## 6. G1. Agent sleep (GUI, experimental)

The agent cannot change this. Only point the user to it: Settings → Experimental → Agent sleep, "Sleep after" from
1 minute to 24 hours (default 30 minutes). It may be missing in some versions.

## 7. Explainer links

The text refers to these only by ID. When the video is published, edit only this table.

| ID | Topic | Explainer |
| --- | --- | --- |
| A0 | Auditing your Orca usage | TBD |
| S1 | Why bundled skills are not installed | TBD |
| R1 | Using the primary as coordinator | TBD |
| R2 | Keeping workspace status current | TBD |
| R3 | Rules for cleaning up finished worktrees | TBD |
| H1 | A hook instead of an instruction | TBD |
| Y1 | orca.yaml shared directories | TBD |
| G1 | Agent sleep | TBD |
