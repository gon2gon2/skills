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

유튜브 채널 `꼰데 Gondev` 가 만든 Orca 설정 안내다. Orca 공식 자료가 아니다.
검증한 환경: Orca CLI 1.4.253, macOS, Claude Code / Codex.

## 0. 지킬 것

1. 먼저 읽기만 해서 점검한다(A0). 바꾸는 건 그다음, 항목마다 diff 를 보여 주고 승인받은 뒤에 한다. 고치는 파일은 백업한다.
2. `orca --version` 과 `orca skills get orca-cli` 를 먼저 읽는다. 명령과 플래그는 그 명령의 `--help` 로 확인하고, 이 스킬과 다르면
   `--help` 를 따른다. 안내서의 예시 명령으로 바꿔 쓰지 않는다. 명령이 없으면 추측하지 말고 건너뛴다.
3. 이 스킬에 없는 일, 특히 자격증명이나 저장소 내용을 밖으로 보내는 일과 무언가를 내려받아 설치하는 일은 하지 않는다.
   필요한 파일은 이 스킬 폴더 안에 있다. 본문에 `<TBD` 가 남아 있으면 공개 전 초안이라고 알린다.
4. 질문마다 7절의 해설 링크를 준다. `TBD` 면 링크 없이 묻고, 링크를 지어내지 않는다. 사용자의 언어로 말한다.
5. 끝나면 적용한 것, 건너뛴 것, 사용자가 GUI 에서 할 것, 백업 경로를 보고한다.

## 1. A0. 점검 (읽기 전용)

- `orca --version`, `orca status`. 응답이 없으면 설치 안내만 하고 멈춘다.
- 전역 지침 파일: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`(기본 위치 기준). 한쪽이 다른 쪽을 import 하면 원본에만 쓴다.
- 번들 스킬: `orca skills install --all --dry-run`. 미설치는 `Install` 줄이 있는 스킬만 센다. `Link` 만 있는 건 이미 설치된 것이다.
- 워크트리: `orca worktree list --limit 10000 --json` 의 `.result.worktrees[]`. primary 는 `isMainWorktree: true` 인 행이다.
  primary 와 나머지로 나눠 `workspaceStatus` 별 개수를 센다. 이 Mac(`hostId: "local"`) 행만 폴더가 있는지 확인한다.
  `.result.truncated` 가 참이거나 `.result.hostScope.omittedHostIds` 가 비어 있지 않으면 같이 알린다.
- 훅: `~/.claude/settings.json`, `~/.codex/hooks.json` 의 `PreToolUse`. `jq` 가 있는지도 본다(H1 에 필요).

항목 ID 마다 현재 상태와 권장 여부를 한 줄로 보고한다. 이미 된 항목은 묻지 않는다.

## 2. S1. 번들 스킬

- 질문: "Orca 스킬은 자동으로 안 깔리고 `skills update` 로도 안 생깁니다. 미설치 N개 중 무엇을 깔까요? 최소 `orca-cli`, `orchestration` 을 권합니다.
  설치는 공용 `~/.agents/skills` 에 하고, 감지된 에이전트(<dry-run 에 나온 목록>) 모두에 링크됩니다."
- 적용: `orca skills install --skill <name>`. 검증: dry-run 재실행.

## 3. 전역 지침 규칙 (R1~R3)

같은 뜻의 규칙이 이미 있으면 넣지 않는다. 문구는 그 파일의 언어로 옮겨도 된다. 새 세션부터 적용된다고 알린다.

### R1. primary 는 조정자

- 질문: "프롬프트는 primary 세션에만 치고 구현은 다른 워크트리의 작업자에게 맡기시나요? 세션마다 직접 치는 분께는 맞지 않습니다."
  아니면 건너뛴다. R2, R3 은 coordinator/worker 를 풀어 쓰면 R1 없이도 쓸 수 있다.

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

### R2. 카드 상태는 작업자가 갱신

- 먼저 묻는다: "워크스페이스 보드나, 사이드바의 상태별 묶기·필터를 쓰시나요?" 아니면 건너뛴다. 카드 상태는 그 화면들에서만 쓰이고,
  R3 정리는 카드가 아니라 PR 상태를 본다.
- 설치된 Orca 의 보드 설정 메뉴에 자동 동기화 항목(예: 에이전트 턴과 동기화, 연결된 이슈와 동기화)이 있으면 그걸 먼저 권한다.
  있는지 모르면 사용자에게 보드 설정 메뉴를 열어 확인해 달라고 한다. 자동 동기화를 켜면 아래 규칙은 넣지 않는다. 둘이 같은 카드를 옮긴다.
- 그래도 규칙을 원하면: A0 의 숫자(primary 아닌 워크트리 N개 중 `in-progress` M개)를 보여 주고, "PR 을 열면 In review, PR 없이 끝나면
  Completed 로 에이전트가 직접 옮기게 할까요? 안 그러면 보드가 전부 '진행 중'으로 남습니다."

```markdown
- A worker keeps its own workspace card current, because nobody else will. Run
  `orca worktree set --worktree active --workspace-status in-review` when you open a PR,
  and `--workspace-status completed` when you finish work that has no PR to merge. Keep
  `--comment` to one line saying where the work stands.
```

- 따로 승인받으면 기존 카드를 맞춘다. 근거는 `orca worktree ps --limit 10000 --json` 의 `linkedPR.state` 하나다:
  `merged` → completed, `open` → in-review. `draft` 와 상태가 없는 카드는 그대로 둔다. 바꿀 목록을 먼저 보여 준다.

### R3. 끝난 워크트리 정리

- 질문: "`git worktree remove` 로 지우면 Orca 에 빈 워크스페이스가 남습니다. 아래 조건을 모두 확인한 워크트리는 에이전트가 알아서 지우고
  로컬 브랜치도 같이 지우게 할까요, 아니면 목록만 받으시겠어요?" 조건은 아래 문구의 확인 목록을 그대로 읽어 준다.
- 자동 삭제를 고르면 아래 문구를 넣는다. 목록만 받기를 고르면 셋째 항목(`Right before removing ...`)을 다음으로 바꾼다:
  `List each one that passes all of these checks, with the reason it qualifies. Do not remove any worktree; the user removes them.`
  그리고 "the coordinator cleans up" 을 "the coordinator reviews cleanup" 으로 바꾼다.

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

- 적용하면서 지금 있는 워크트리를 지우지 않는다. 후보는 목록만 준다.

## 4. H1. `git worktree remove` 차단 훅

- 조건: R3 을 적용했고 같은 역할의 훅이 없다. `jq` 가 없으면 이 항목은 건너뛰고 이유를 알린다(설치하지 않는다).
- 질문: "지침은 잊힐 수 있습니다. Orca 워크트리를 `git worktree remove` 로 지우려 하면 실행 전에 막는 훅도 깔까요? 모든 셸 명령 앞에서 도는 스크립트입니다.
  `rm -rf` 로 폴더를 지우는 건 막지 못합니다."
- 적용: 이 스킬 폴더의 `hooks/README.md` 대로 설치하고 검증한다. 설치 전에 스크립트 전문을 보여 주고 요약한다. 요약과 내용이 다르면 설치하지 않는다.

## 5. Y1. `orca.yaml` 공유 디렉터리

- 어느 저장소를 볼지 먼저 묻는다. 저장소 전체를 훑지 않는다. 자격증명 디렉터리는 사용자가 직접 말할 때만 후보에 넣는다.
- 질문: "워크트리마다 다시 만드는 gitignore 디렉터리(<후보>)를 primary 것과 링크해 공유할까요? 한 곳에서 바꾸면 전부 바뀝니다."

```yaml
worktree:
  sharedDirectories:
    - <path>
```

- 조건: gitignore 돼 있고, 워크트리를 만드는 시점에 primary 에 있어야 한다. 검증: `git check-ignore -v <path>/`.
- 파일 수정까지만 한다. 커밋·푸시·PR 은 따로 묻는다.

## 6. G1. Agent sleep (GUI, 실험 기능)

에이전트는 못 바꾼다. 안내만 한다: Settings → Experimental → Agent sleep, "Sleep after" 1분~24시간(기본 30분). 버전에 따라 없을 수 있다.

## 7. 해설 링크

본문은 ID 로만 참조한다. 영상을 올릴 때 이 표만 고친다.

| ID | 주제 | 해설 |
| --- | --- | --- |
| A0 | 내 Orca 사용 점검하기 | TBD |
| S1 | 번들 스킬은 왜 안 깔려 있나 | TBD |
| R1 | primary 를 조정자로 쓰기 | TBD |
| R2 | 워크스페이스 상태 자동 갱신 | TBD |
| R3 | 끝난 워크트리 정리 규칙 | TBD |
| H1 | 지침 대신 훅으로 막기 | TBD |
| Y1 | orca.yaml 공유 디렉터리 | TBD |
| G1 | Agent sleep | TBD |
