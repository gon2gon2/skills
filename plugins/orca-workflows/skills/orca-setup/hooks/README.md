# orca-worktree-guard

A PreToolUse hook that stops `git worktree remove` on a worktree Orca manages, before it runs, and suggests the
`orca worktree rm` command instead. Paths Orca does not know about pass through.

Requires `jq` (included with macOS 15 and later). Without it the hook blocks nothing, so skip installing it.

## Install

1. Copy `orca-worktree-guard.sh` from this folder to `~/.agents/hooks/` and make it executable. Do not point at the
   plugin cache path directly; it changes with every version.
2. Claude Code: add this to `hooks.PreToolUse` in `~/.claude/settings.json`.

   ```json
   {
     "matcher": "Bash",
     "hooks": [
       { "type": "command", "command": "sh \"$HOME/.agents/hooks/orca-worktree-guard.sh\"", "timeout": 10 }
     ]
   }
   ```

3. Codex: add the same entry at the **end** of the `hooks.PreToolUse` array in `~/.codex/hooks.json`. Putting it
   earlier shifts the index of Orca's own hook trust state. Afterwards the user must trust it in Codex with `/hooks`.

## Verify

1. `sh <this folder>/test.sh` runs against a fake `orca` and never touches real worktrees. The last line must be
   `N passed, 0 failed`.
2. Feed only the payload with a real Orca worktree path `<wt>` (the command is not run). It must exit 2 with the
   message.

   ```bash
   printf '{"tool_input":{"command":"git worktree remove <wt>"}}' | sh ~/.agents/hooks/orca-worktree-guard.sh
   ```

3. Check that it fires in an agent session (Claude Code and Codex separately). First confirm that
   `test -e /nonexistent-orca-guard-check` fails (the path does not exist). Open a new session and have the agent run
   the command below, with `<wt>` as an absolute path in quotes.

   ```bash
   git -C /nonexistent-orca-guard-check worktree remove "<wt>"
   ```

   If the hook fires, the command is blocked before it runs. If it does not, git fails right away because the `-C`
   directory does not exist, so the worktree is not removed. Seeing git's `cannot change to` error means the hook is
   not registered.

## Limits and undo

- This guards against mistakes; it is not a security boundary. It does not see:
  - deleting the folder directly, as in `rm -rf <wt>`
  - commands inside `sh -c "..."` or `bash -c "..."`
  - paths built from variables or `$(...)`
- It looks past wrappers such as `command`, `env` and `sudo`. Heredoc bodies are treated as data, not commands, and
  ignored.
- If `jq` or `orca` is missing, or the app does not respond, it lets the command through.
- To bypass once, prefix the command with `ORCA_WT_GUARD=off`.
- Undo: remove the hook entry you added and the script file.
