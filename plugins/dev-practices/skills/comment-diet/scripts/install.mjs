#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PAYLOAD = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../payload");
const EXIT_BAD_PLAN = 2;
const EXIT_CONFLICT = 3;
const EXIT_CHECK_FAILED = 4;

function fail(code, message) {
  console.error(`comment-diet: ${message}`);
  process.exit(code);
}

const args = process.argv.slice(2);
const apply = args.includes("--apply");
const force = args.includes("--force");
const planPath = args.find((arg) => !arg.startsWith("--"));
if (!planPath) fail(EXIT_BAD_PLAN, "usage: install.mjs <plan.json> [--apply] [--force]");

const plan = JSON.parse(fs.readFileSync(planPath, "utf8"));
const target = path.resolve(plan.target ?? ".");
let root;
try {
  root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: target, encoding: "utf8" }).trim();
} catch {
  fail(EXIT_BAD_PLAN, `${target} is not inside a git repository`);
}

function inside(relative, name) {
  if (typeof relative !== "string" || relative === "" || path.isAbsolute(relative) || relative.split("/").includes("..")) {
    fail(EXIT_BAD_PLAN, `${name} must be a path relative to the repo root, got ${JSON.stringify(relative)}`);
  }
  return relative.replace(/\/$/, "");
}

const lintDir = inside(plan.lintDir, "lintDir");
const skillDirs = (plan.skillDirs ?? []).map((dir) => inside(dir, "skillDirs[]"));
const decisions = plan.decisions ?? {};
const issues = plan.issues ?? {};
const ci = plan.ci ?? { kind: "none" };
const packageScript = plan.packageScript ?? null;
const run = plan.run ?? `node ${lintDir}/comments.mjs`;
if (!["github-actions", "none"].includes(ci.kind)) fail(EXIT_BAD_PLAN, `ci.kind must be "github-actions" or "none"`);
if (typeof decisions.howto !== "string" || !decisions.howto.trim()) fail(EXIT_BAD_PLAN, "decisions.howto is required: one or two sentences on where a new decision record goes");
if (typeof issues.howto !== "string" || !issues.howto.trim()) fail(EXIT_BAD_PLAN, "issues.howto is required: one sentence on how an issue is filed in this repo");

function render(template, values) {
  const text = fs.readFileSync(path.join(PAYLOAD, template), "utf8").replace(/\{\{([A-Z_]+)\}\}/g, (whole, key) => {
    if (!(key in values)) fail(EXIT_BAD_PLAN, `template ${template} wants ${key}`);
    return values[key];
  });
  return text;
}

function runsOn(value) {
  const list = Array.isArray(value);
  const lines = list ? value : String(value ?? "ubuntu-latest").split("\n");
  if (lines.some((line) => typeof line !== "string")) fail(EXIT_BAD_PLAN, "ci.runsOn must be a runner label or a list of labels");
  const kept = lines.map((line) => line.trim()).filter(Boolean);
  if (kept.length === 0) fail(EXIT_BAD_PLAN, "ci.runsOn must be a runner label or a list of labels");
  if (!list && lines.length === 1) return ` ${kept[0]}`;
  return kept.map((line) => `\n      ${list ? "- " : ""}${line}`).join("");
}

const values = {
  RUN: run,
  LINT_DIR: lintDir,
  RULE_SENTENCE: plan.rule ? ` (${plan.rule})` : "",
  DECISIONS: decisions.path ? `\`${decisions.path}\`` : "the decision records",
  DECISION_HOWTO: decisions.howto.trim(),
  ISSUES_HOWTO: issues.howto.trim(),
  VERIFY_SENTENCE: plan.verify ? `: \`${plan.verify}\`` : "",
  RUNS_ON: runsOn(ci.runsOn),
  INSTALL_STEP: ci.install ? `      - run: ${ci.install}\n` : "",
  DATE: plan.date ?? new Date().toISOString().slice(0, 10),
};

const wanted = [];
const add = (relative, content, mode) => wanted.push({ relative, content, mode });

for (const name of ["comments.mjs", "comments.test.mjs", "py_comments.py"]) {
  add(`${lintDir}/${name}`, fs.readFileSync(path.join(PAYLOAD, "comment-lint", name), "utf8"), name === "comments.mjs" ? 0o755 : 0o644);
}
const config = {
  exclude: plan.exclude ?? [],
  languages: plan.languages ?? ["ts", "py", "sh", "sql", "hash"],
  run,
  rule: plan.rule ?? "",
  decisions: decisions.path ?? "",
};
add(`${lintDir}/config.json`, `${JSON.stringify(config, null, 2)}\n`);
for (const dir of skillDirs) {
  add(`${dir}/delete-comment/SKILL.md`, render("skill/SKILL.md.tmpl", values));
  add(`${dir}/delete-comment/classify-brief.md`, render("skill/classify-brief.md.tmpl", values));
}
if (ci.kind === "github-actions") add(".github/workflows/check-comments.yml", render("ci/github-actions.yml.tmpl", values));
if (decisions.scaffold) {
  const dir = inside(decisions.path, "decisions.path");
  add(`${dir}/README.md`, render("decisions/README.md.tmpl", values));
  add(`${dir}/0001-no-code-comments.md`, render("decisions/0001-no-code-comments.md.tmpl", values));
}

const actions = [];
for (const file of wanted) {
  const full = path.join(root, file.relative);
  if (!fs.existsSync(full)) actions.push({ ...file, action: "create" });
  else if (fs.readFileSync(full, "utf8") === file.content) actions.push({ ...file, action: "unchanged" });
  else actions.push({ ...file, action: force ? "overwrite" : "conflict" });
}

let packageEdit = null;
if (packageScript) {
  const full = path.join(root, "package.json");
  if (!fs.existsSync(full)) fail(EXIT_BAD_PLAN, "packageScript is set and there is no package.json at the repo root");
  const raw = fs.readFileSync(full, "utf8");
  const parsed = JSON.parse(raw);
  const command = `node ${lintDir}/comments.mjs`;
  const current = parsed.scripts?.[packageScript];
  if (current === command) packageEdit = { action: "unchanged" };
  else if (current !== undefined && !force) packageEdit = { action: "conflict" };
  else {
    const indent = /^(\s+)"/m.exec(raw)?.[1] ?? "  ";
    parsed.scripts = { ...(parsed.scripts ?? {}), [packageScript]: command };
    packageEdit = { action: current === undefined ? "create" : "overwrite", content: `${JSON.stringify(parsed, null, indent)}${raw.endsWith("\n") ? "\n" : ""}` };
  }
  actions.push({ relative: `package.json (scripts.${packageScript})`, action: packageEdit.action });
}

let agentEdit = null;
if (plan.agentFile) {
  const relative = inside(plan.agentFile, "agentFile");
  const full = path.join(root, relative);
  const before = fs.existsSync(full) ? fs.readFileSync(full, "utf8") : "";
  const heading = "## Code comments";
  if (before.includes(heading)) agentEdit = { action: "unchanged" };
  else {
    const skill = skillDirs[0] ? ` To remove existing ones, use the \`delete-comment\` skill in \`${skillDirs[0]}/delete-comment/\`.` : "";
    const section = `${heading}\n\nDo not write code comments${plan.rule ? ` (${plan.rule})` : ""}. \`${run} check\` fails on any comment line that is not in \`${lintDir}/baseline.json\`. Put a reason in a test, a type, a name or a decision record, and file an issue for a shortcut.${skill}\n`;
    agentEdit = { action: before ? "append" : "create", relative, content: `${before}${before && !before.endsWith("\n") ? "\n" : ""}${before ? "\n" : ""}${section}` };
  }
  actions.push({ relative: `${relative} (section "Code comments")`, action: agentEdit.action });
}

for (const item of actions) console.log(`${item.action.padEnd(10)} ${item.relative}`);
const conflicts = actions.filter((item) => item.action === "conflict");
if (conflicts.length) fail(EXIT_CONFLICT, `${conflicts.length} file(s) already exist with different content. Compare them, then re-run with --force to replace them.`);
if (!apply) {
  console.log("comment-diet: dry run, nothing written. Re-run with --apply.");
  process.exit(0);
}

for (const item of actions) {
  if (!item.content || item.action === "unchanged") continue;
  const full = path.join(root, item.relative);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, item.content, item.mode ? { mode: item.mode } : undefined);
}
if (packageEdit?.content) fs.writeFileSync(path.join(root, "package.json"), packageEdit.content);
if (agentEdit?.content) fs.writeFileSync(path.join(root, agentEdit.relative), agentEdit.content);

const lint = path.join(root, lintDir, "comments.mjs");
const node = (extra) => spawnSync(process.execPath, [lint, ...extra], { cwd: root, encoding: "utf8" });
const hadBaseline = fs.existsSync(path.join(root, lintDir, "baseline.json"));
if (!hadBaseline) {
  const created = node(["baseline", "--init"]);
  process.stdout.write(created.stdout);
  if (created.status !== 0) fail(EXIT_CHECK_FAILED, `baseline --init failed:\n${created.stderr}`);
}
const lintReplaced = actions.some((item) => item.action === "overwrite" && item.relative.startsWith(`${lintDir}/`));
if (lintReplaced && hadBaseline) {
  const lowered = node(["baseline"]);
  process.stdout.write(lowered.stdout);
  if (lowered.status !== 0) fail(EXIT_CHECK_FAILED, `the replaced lint could not lower the baseline:\n${lowered.stderr}`);
}
const checked = node(["check"]);
process.stdout.write(checked.stdout);
if (checked.status !== 0) fail(EXIT_CHECK_FAILED, `check failed:\n${checked.stderr}`);
const counted = node(["count", "--json"]);
if (counted.status === 0) {
  const total = JSON.parse(counted.stdout).total;
  const share = total.sourceLines ? ((total.lines / total.sourceLines) * 100).toFixed(1) : "0";
  console.log(`comment-diet: ${total.lines} comment lines in ${total.withComments} of ${total.files} files (${share}% of ${total.sourceLines} lines), ${total.directives} directives left alone`);
}
