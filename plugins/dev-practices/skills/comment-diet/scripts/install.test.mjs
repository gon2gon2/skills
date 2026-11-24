import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HASH = "#";

function sh(cwd, command, args) {
  return spawnSync(command, args, { cwd, encoding: "utf8" });
}

function makeRepo() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "comment-diet-")));
  sh(dir, "git", ["init", "-q"]);
  fs.mkdirSync(path.join(dir, "scripts"));
  fs.mkdirSync(path.join(dir, "docs"));
  fs.writeFileSync(path.join(dir, "scripts/run.sh"), `${HASH}!/usr/bin/env bash\n${HASH} old note\necho hi\n`);
  fs.writeFileSync(path.join(dir, "docs/setup.sh"), `${HASH} prose example\necho doc\n`);
  fs.writeFileSync(path.join(dir, "AGENTS.md"), "# Agents\n");
  sh(dir, "git", ["add", "-A"]);
  return dir;
}

function plan(dir, extra) {
  const file = path.join(dir, "plan.json");
  fs.writeFileSync(
    file,
    JSON.stringify({
      target: dir,
      lintDir: "tools/comment-lint",
      exclude: ["docs/"],
      languages: ["sh", "hash"],
      skillDirs: [".claude/skills"],
      decisions: { path: "docs/decisions", scaffold: true, howto: "Add a record to `docs/decisions/`." },
      issues: { howto: "File them with `gh issue create`." },
      ci: { kind: "github-actions" },
      agentFile: "AGENTS.md",
      ...extra,
    }),
  );
  return file;
}

const install = (dir, args) => sh(dir, process.execPath, [path.join(HERE, "install.mjs"), ...args]);
const lint = (dir, args) => sh(dir, process.execPath, [path.join(dir, "tools/comment-lint/comments.mjs"), ...args]);

test("a dry run writes nothing", () => {
  const dir = makeRepo();
  const run = install(dir, [plan(dir)]);
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /create\s+tools\/comment-lint\/comments\.mjs/);
  assert.ok(!fs.existsSync(path.join(dir, "tools")));
});

test("apply installs the lint, the skill, the workflow and the first record", () => {
  const dir = makeRepo();
  const run = install(dir, [plan(dir), "--apply"]);
  assert.equal(run.status, 0, run.stderr);
  for (const file of [
    "tools/comment-lint/comments.mjs",
    "tools/comment-lint/config.json",
    "tools/comment-lint/baseline.json",
    ".claude/skills/delete-comment/SKILL.md",
    ".claude/skills/delete-comment/classify-brief.md",
    ".github/workflows/check-comments.yml",
    "docs/decisions/0001-no-code-comments.md",
  ]) {
    assert.ok(fs.existsSync(path.join(dir, file)), file);
  }
  const skill = fs.readFileSync(path.join(dir, ".claude/skills/delete-comment/SKILL.md"), "utf8");
  assert.ok(!skill.includes("{{"));
  assert.ok(skill.includes("node tools/comment-lint/comments.mjs strip"));
  assert.match(fs.readFileSync(path.join(dir, "AGENTS.md"), "utf8"), /## Code comments/);
  const baseline = JSON.parse(fs.readFileSync(path.join(dir, "tools/comment-lint/baseline.json"), "utf8"));
  assert.deepEqual(Object.keys(baseline.files), ["scripts/run.sh"]);
});

test("the installed check rejects a new comment, a reworded one and a stale baseline", () => {
  const dir = makeRepo();
  assert.equal(install(dir, [plan(dir, { ci: { kind: "none" } }), "--apply"]).status, 0);
  sh(dir, "git", ["add", "-A"]);
  assert.equal(lint(dir, ["check"]).status, 0);

  const script = path.join(dir, "scripts/run.sh");
  const original = fs.readFileSync(script, "utf8");
  fs.writeFileSync(script, `${original}${HASH} brand new\n`);
  assert.equal(lint(dir, ["check"]).status, 1);

  fs.writeFileSync(script, original.replace("old note", "new wording"));
  assert.equal(lint(dir, ["check"]).status, 1);
  assert.equal(lint(dir, ["baseline"]).status, 1);

  fs.writeFileSync(script, original);
  assert.equal(lint(dir, ["strip", "scripts"]).status, 0);
  assert.equal(fs.readFileSync(script, "utf8"), `${HASH}!/usr/bin/env bash\necho hi\n`);
  assert.equal(lint(dir, ["check"]).status, 1);
  assert.equal(lint(dir, ["baseline"]).status, 0);
  assert.equal(lint(dir, ["check"]).status, 0);
});

test("a second install is a no-op and a changed file is a conflict", () => {
  const dir = makeRepo();
  const file = plan(dir);
  assert.equal(install(dir, [file, "--apply"]).status, 0);
  const again = install(dir, [file, "--apply"]);
  assert.equal(again.status, 0, again.stderr);
  assert.ok(!/create|overwrite/.test(again.stdout));
  fs.appendFileSync(path.join(dir, ".claude/skills/delete-comment/SKILL.md"), "local edit\n");
  assert.equal(install(dir, [file, "--apply"]).status, 3);
  assert.equal(install(dir, [file, "--apply", "--force"]).status, 0);
});

test("replacing an older lint lowers the baseline for lines that stopped counting", { skip: sh(".", "python3", ["--version"]).status !== 0 }, () => {
  const dir = makeRepo();
  const metadata = [`${HASH} /// script`, `${HASH} dependencies = []`, `${HASH} ///`];
  fs.writeFileSync(path.join(dir, "scripts/tool.py"), [...metadata, `${HASH} old note`, "x = 1", ""].join("\n"));
  sh(dir, "git", ["add", "-A"]);
  const file = plan(dir, { languages: ["py", "sh", "hash"], ci: { kind: "none" } });
  assert.equal(install(dir, [file, "--apply"]).status, 0);

  const installed = path.join(dir, "tools/comment-lint/comments.mjs");
  const current = fs.readFileSync(installed, "utf8");
  const older = current.replace('const metadata = lang === "py" ? inlineMetadataStarts(text) : new Set();', "const metadata = new Set();");
  assert.notEqual(older, current);
  fs.writeFileSync(installed, older);
  fs.rmSync(path.join(dir, "tools/comment-lint/baseline.json"));
  assert.equal(lint(dir, ["baseline", "--init"]).status, 0);
  const prints = () => JSON.parse(fs.readFileSync(path.join(dir, "tools/comment-lint/baseline.json"), "utf8")).files["scripts/tool.py"].split(" ");
  assert.equal(prints().length, 4);

  assert.equal(install(dir, [file, "--apply"]).status, 3);
  const upgraded = install(dir, [file, "--apply", "--force"]);
  assert.equal(upgraded.status, 0, upgraded.stderr);
  assert.match(upgraded.stdout, /baseline lowered from 5 to 2/);
  assert.equal(prints().length, 1);
  assert.equal(lint(dir, ["strip", "scripts/tool.py"]).status, 0);
  assert.equal(fs.readFileSync(path.join(dir, "scripts/tool.py"), "utf8"), [...metadata, "x = 1", ""].join("\n"));
});

test("a runner label list is written as a list with no trailing space", () => {
  const dir = makeRepo();
  const workflow = () => fs.readFileSync(path.join(dir, ".github/workflows/check-comments.yml"), "utf8");
  const label = "codebuild-ci-${{ github.run_id }}-${{ github.run_attempt }}";
  assert.equal(install(dir, [plan(dir, { ci: { kind: "github-actions", runsOn: [label] } }), "--apply"]).status, 0);
  assert.ok(workflow().includes(`    runs-on:\n      - ${label}\n    steps:`));
  assert.equal(install(dir, [plan(dir, { ci: { kind: "github-actions", runsOn: `\n      - ${label}` } }), "--apply"]).status, 0);
  assert.ok(!/[ \t]\n/.test(workflow()));
  assert.equal(install(dir, [plan(dir, { ci: { kind: "github-actions" } }), "--apply", "--force"]).status, 0);
  assert.ok(workflow().includes("    runs-on: ubuntu-latest\n"));
});

test("a plan that points outside the repo is refused", () => {
  const dir = makeRepo();
  assert.equal(install(dir, [plan(dir, { lintDir: "../elsewhere" })]).status, 2);
});

test("detect reports what the plan needs", () => {
  const dir = makeRepo();
  const run = sh(dir, process.execPath, [path.join(HERE, "detect.mjs"), dir]);
  assert.equal(run.status, 0, run.stderr);
  const found = JSON.parse(run.stdout);
  assert.equal(found.root, dir);
  assert.deepEqual(found.languages, { sh: 2 });
  assert.deepEqual(found.excludeCandidates, ["docs"]);
  assert.deepEqual(found.agentFiles, ["AGENTS.md"]);
  assert.deepEqual(found.installed, []);
});
