#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const target = path.resolve(process.argv[2] ?? ".");

function git(args) {
  return execFileSync("git", args, { cwd: target, encoding: "utf8", maxBuffer: 1 << 26, stdio: ["ignore", "pipe", "ignore"] }).trim();
}

function version(command, args) {
  const run = spawnSync(command, args, { encoding: "utf8" });
  return run.status === 0 ? (run.stdout || run.stderr).trim().split("\n")[0] : null;
}

function exists(relative) {
  return fs.existsSync(path.join(root, relative));
}

let root;
try {
  root = git(["rev-parse", "--show-toplevel"]);
} catch {
  console.error(JSON.stringify({ error: "not_a_git_repository", target }));
  process.exit(2);
}

const files = git(["ls-files"]).split("\n").filter(Boolean);

const SCANNED = [
  ["ts", /\.(ts|tsx|mjs|cjs|js)$/],
  ["py", /\.py$/],
  ["sh", /\.sh$/],
  ["sql", /\.sql$/],
  ["hash", /(\.(ya?ml|conf|env|properties)$)|((^|\/)(Dockerfile|dockerignore)[^/]*$)|((^|\/)\.(gitignore|dockerignore|env\.example)$)/],
];
const NOT_SCANNED = /\.(go|rs|java|kt|kts|swift|rb|php|cs|c|h|cc|cpp|hpp|scala|dart|lua|tf|vue|svelte|css|scss|html)$/;
const VENDORED = /(^|\/)(node_modules|vendor|third_party|dist|build)\//;

const languages = {};
const notScanned = {};
const topDirs = {};
for (const file of files) {
  if (VENDORED.test(file)) continue;
  const hit = SCANNED.find(([, pattern]) => pattern.test(file));
  if (hit) {
    languages[hit[0]] = (languages[hit[0]] ?? 0) + 1;
    const top = file.includes("/") ? file.split("/")[0] : ".";
    topDirs[top] = (topDirs[top] ?? 0) + 1;
    continue;
  }
  const other = NOT_SCANNED.exec(file);
  if (other) notScanned[other[1]] = (notScanned[other[1]] ?? 0) + 1;
}

const dirs = new Set();
for (const file of files) {
  const parts = file.split("/");
  for (let depth = 1; depth < Math.min(parts.length, 4); depth += 1) dirs.add(parts.slice(0, depth).join("/"));
}

const EXCLUDE_NAMES = /^(docs?|documentation|fixtures?|__fixtures__|__snapshots__|snapshots|testdata|generated|gen|migrations|patches|examples?|samples?|public|static|assets)$/;
const excludeCandidates = [...dirs].filter((dir) => EXCLUDE_NAMES.test(path.basename(dir)) && dir.split("/").length <= 2).sort();

const DECISION_NAMES = /^(adrs?|decisions?|rfcs?|architecture-decisions|design-docs?)$/i;
const decisionDirs = [...dirs].filter((dir) => DECISION_NAMES.test(path.basename(dir))).sort();
const decisionFiles = files.filter((file) => /\.(md|mdx|adoc|rst)$/.test(file) && /(^|[/_-])(adrs?|decisions?)([._-]|$)/i.test(path.basename(file)) && !decisionDirs.some((dir) => file.startsWith(`${dir}/`)));
const decisions = [
  ...decisionDirs.map((dir) => {
    const entries = files.filter((file) => file.startsWith(`${dir}/`) && path.dirname(file) === dir).map((file) => path.basename(file)).sort();
    const numbered = entries.filter((name) => /^(ADR-?)?\d+/i.test(name));
    return { path: dir, kind: "directory", entries: entries.length, lastNumbered: numbered[numbered.length - 1] ?? null, sample: entries.slice(0, 3) };
  }),
  ...decisionFiles.map((file) => {
    const text = fs.readFileSync(path.join(root, file), "utf8");
    const headings = text.split("\n").filter((line) => /^#{1,3}\s+.*\b(ADR|RFC)?[- ]?\d+/i.test(line));
    return { path: file, kind: "single-file", entries: headings.length, lastHeading: headings[headings.length - 1] ?? null };
  }),
];

const skillDirs = [".claude/skills", ".agents/skills", ".codex/skills", ".cursor/skills"].filter(exists);
const agentFiles = ["AGENTS.md", "CLAUDE.md", ".cursorrules", ".github/copilot-instructions.md"].filter(exists);

const workflows = files
  .filter((file) => /^\.github\/workflows\/[^/]+\.ya?ml$/.test(file))
  .map((file) => {
    const text = fs.readFileSync(path.join(root, file), "utf8");
    const runsOn = [...new Set([...text.matchAll(/^\s*runs-on:\s*(.+)$/gm)].map((match) => match[1].trim()))];
    return { file, pullRequest: /^\s*pull_request(_target)?:?/m.test(text), runsOn };
  });
const otherCi = [".gitlab-ci.yml", ".circleci/config.yml", "Jenkinsfile", "azure-pipelines.yml", "bitbucket-pipelines.yml", ".buildkite/pipeline.yml"].filter(exists);

let packageJson = null;
if (exists("package.json")) {
  const parsed = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const tracked = (name) => files.includes(name);
  const manager = tracked("pnpm-lock.yaml") ? "pnpm" : tracked("yarn.lock") ? "yarn" : tracked("bun.lockb") || tracked("bun.lock") ? "bun" : "npm";
  packageJson = { manager, type: parsed.type ?? "commonjs", scripts: Object.keys(parsed.scripts ?? {}), hasCommentsScript: Boolean(parsed.scripts?.comments) };
}

let typescript = false;
try {
  createRequire(path.join(root, "package.json")).resolve("typescript");
  typescript = true;
} catch {}

let remote = null;
try {
  const url = git(["remote", "get-url", "origin"]);
  const match = /[:/]([^/:]+\/[^/]+?)(\.git)?$/.exec(url);
  remote = { host: /github\.com/.test(url) ? "github" : /gitlab/.test(url) ? "gitlab" : /bitbucket/.test(url) ? "bitbucket" : "other", slug: match ? match[1] : null };
} catch {}

const installed = files.filter((file) => /(^|\/)comment-lint\/comments\.mjs$/.test(file)).map((file) => path.dirname(file));
const lintDirCandidates = ["tools", "scripts", "infrastructure", "infra", "build", "dev", ".github/scripts"].filter((dir) => dirs.has(dir));

const bashMajor = spawnSync("bash", ["-c", "echo ${BASH_VERSINFO[0]}"], { encoding: "utf8" });

process.stdout.write(
  `${JSON.stringify(
    {
      root,
      installed,
      tools: {
        node: process.version,
        python3: version("python3", ["--version"]),
        bashMajor: bashMajor.status === 0 ? Number(bashMajor.stdout.trim()) : null,
        gh: version("gh", ["--version"]) !== null,
        typescriptResolvable: typescript,
      },
      languages,
      notScanned,
      topDirs,
      excludeCandidates,
      lintDirCandidates,
      decisions,
      skillDirs,
      agentFiles,
      ci: { githubWorkflows: workflows, other: otherCi },
      packageJson,
      remote,
    },
    null,
    2,
  )}\n`,
);
