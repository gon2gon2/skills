#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BASELINE = path.join(HERE, "baseline.json");
const PY_HELPER = path.join(HERE, "py_comments.py");
const CONFIG_FILE = path.join(HERE, "config.json");

const DEFAULTS = {
  exclude: [],
  languages: ["ts", "py", "sh", "sql", "hash"],
  run: "node comments.mjs",
  rule: "",
  decisions: "",
};
const CONFIG = { ...DEFAULTS, ...(fs.existsSync(CONFIG_FILE) ? JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")) : {}) };

let root = null;
function repoRoot() {
  if (!root) root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE, encoding: "utf8" }).trim();
  return root;
}

const ALWAYS_EXCLUDED = [/(^|\/)(node_modules|vendor|third_party|dist|build|\.git)\//, /\.min\.(js|mjs|cjs)$/];

export function excludePattern(entry) {
  if (!entry.includes("*")) return new RegExp(`^${entry.replace(/[.+?^${}()|[\]\\]/g, "\\$&")}`);
  const body = entry
    .split(/(\*\*\/|\*\*|\*)/)
    .map((part) => {
      if (part === "**/") return "(?:.*/)?";
      if (part === "**") return ".*";
      if (part === "*") return "[^/]*";
      return part.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
    })
    .join("");
  return new RegExp(`^${body}`);
}

const EXCLUDED = [...ALWAYS_EXCLUDED, ...CONFIG.exclude.map(excludePattern)];
const LANGUAGES = new Set(CONFIG.languages);

const STRIPPABLE = new Set(["ts", "py", "sh"]);

const DIRECTIVES = {
  ts: [
    /^\/[/*]\s*@ts-(expect-error|ignore|nocheck|check)\b/,
    /^\/[/*]\s*eslint-(disable|enable)\b/,
    /^\/[/*]\s*(prettier|biome)-ignore\b/,
    /^\/[/*]\s*(istanbul|c8|v8) ignore\b/,
    /^\/\*\s*(webpack[A-Z]|@vite-ignore|[#@]__PURE__)/,
    /^\/[/*]\s*@(jest|vitest)-environment\b/,
    /^\/\/\/\s*</,
  ],
  py: [/^#!/, /^#\s*(type:|noqa\b|pragma\b|pylint:|fmt:|isort:|mypy:|pyright:|ruff:|nosec\b)/, /^#.*coding[:=]/],
  sh: [/^#!/, /^#\s*shellcheck\s/],
  hash: [/^#!/, /^#\s*(syntax|escape|check)=/, /^#\s*yaml-language-server/, /^#cloud-config/],
  sql: [/^\/\*!/],
};

function languageOf(file) {
  const base = path.basename(file);
  if (/\.(ts|tsx|mjs|cjs|js)$/.test(base)) return "ts";
  if (base.endsWith(".py")) return "py";
  if (base.endsWith(".sh")) return "sh";
  if (base.endsWith(".sql")) return "sql";
  if (/\.(ya?ml|conf|env|properties)$/.test(base)) return "hash";
  if (/^(Dockerfile|dockerignore)/.test(base) || /^\.(gitignore|dockerignore|env\.example)$/.test(base)) return "hash";
  return null;
}

function trackedFiles(selectors) {
  const ROOT = repoRoot();
  const listed = execFileSync("git", ["ls-files"], { cwd: ROOT, encoding: "utf8", maxBuffer: 1 << 26 })
    .split("\n")
    .filter(Boolean);
  const wanted = selectors.map((selector) => path.relative(ROOT, path.resolve(selector)).replace(/\/$/, ""));
  return listed.filter((file) => {
    if (EXCLUDED.some((pattern) => pattern.test(file))) return false;
    if (!LANGUAGES.has(languageOf(file))) return false;
    if (!fs.existsSync(path.join(ROOT, file))) return false;
    if (wanted.length === 0) return true;
    return wanted.some((selector) => selector === "" || file === selector || file.startsWith(`${selector}/`));
  });
}

function isDirective(lang, text) {
  return DIRECTIVES[lang].some((pattern) => pattern.test(text));
}

let typescript = null;
async function loadTypescript() {
  if (typescript) return typescript;
  const bases = [HERE];
  try {
    bases.unshift(repoRoot());
  } catch {}
  for (const base of bases) {
    try {
      const resolved = createRequire(path.join(base, "package.json")).resolve("typescript");
      typescript = (await import(pathToFileURL(resolved).href)).default;
      return typescript;
    } catch {}
  }
  throw new Error("comment-lint: JavaScript and TypeScript files need the `typescript` package. Add it as a dev dependency, or drop \"ts\" from languages in config.json.");
}

function scriptKind(ts, file) {
  if (file.endsWith(".tsx")) return ts.ScriptKind.TSX;
  if (file.endsWith(".ts")) return ts.ScriptKind.TS;
  return ts.ScriptKind.JS;
}

function jsxValue(raw) {
  const lines = raw.split(/\r?\n/);
  const kept = [];
  lines.forEach((line, index) => {
    let value = line.replace(/\t/g, " ");
    if (index !== 0) value = value.replace(/^ +/, "");
    if (index !== lines.length - 1) value = value.replace(/ +$/, "");
    if (value) kept.push(value);
  });
  return kept.join(" ");
}

function tsAnalyse(ts, file, text) {
  const SK = ts.SyntaxKind;
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, scriptKind(ts, file));
  const found = new Map();
  const isJsDoc = (node) => node.kind >= SK.FirstJSDocNode && node.kind <= SK.LastJSDocNode;
  const isJsxBody = (node) => Boolean(node) && (node.kind === SK.JsxElement || node.kind === SK.JsxFragment);
  const add = (pos, end, owner) => {
    if (found.has(pos)) return;
    const emptyJsx = owner && owner.kind === SK.CloseBraceToken && owner.parent.kind === SK.JsxExpression && !owner.parent.expression;
    found.set(pos, {
      pos,
      end,
      text: text.slice(pos, end),
      maskPos: emptyJsx ? owner.parent.getStart(source) : pos,
      maskEnd: emptyJsx ? owner.parent.end : end,
    });
  };
  const trailingAllowed = (token) => {
    if (token.kind === SK.OpenBraceToken && token.parent.kind === SK.JsxExpression && !token.parent.expression) return false;
    if (token.kind === SK.CloseBraceToken) {
      return token.parent.kind !== SK.JsxExpression || !isJsxBody(token.parent.parent);
    }
    if (token.kind === SK.GreaterThanToken) {
      const parent = token.parent;
      if (parent.kind === SK.JsxOpeningElement) return token.end !== parent.end;
      if (parent.kind === SK.JsxOpeningFragment) return false;
      if (parent.kind === SK.JsxSelfClosingElement) return token.end !== parent.end || !isJsxBody(parent.parent);
      if (parent.kind === SK.JsxClosingElement || parent.kind === SK.JsxClosingFragment) {
        return !isJsxBody(parent.parent.parent);
      }
    }
    return true;
  };
  const visitToken = (token) => {
    if (token.pos === token.end) return;
    if (token.kind !== SK.JsxText) {
      const start = token.pos === 0 ? (ts.getShebang(text) ?? "").length : token.pos;
      ts.forEachLeadingCommentRange(text, start, (pos, end) => add(pos, end, token));
    }
    if (trailingAllowed(token)) ts.forEachTrailingCommentRange(text, token.end, (pos, end) => add(pos, end, null));
  };
  const shape = (node) => {
    if (isJsDoc(node)) return null;
    const children = node.getChildren(source);
    if (node.kind === SK.JsxExpression && !node.expression) {
      const close = children[children.length - 1];
      ts.forEachTrailingCommentRange(text, children[0].end, (pos, end) => add(pos, end, close));
      ts.forEachLeadingCommentRange(text, children[0].end, (pos, end) => add(pos, end, close));
      children.forEach(visitToken);
      return null;
    }
    if (children.length === 0) {
      visitToken(node);
      if (node.kind === SK.JsxText) return { jsx: jsxValue(text.slice(node.pos, node.end)) };
      return `${node.kind}:${text.slice(node.getStart(source), node.end)}`;
    }
    const parts = [];
    for (const child of children) {
      const part = shape(child);
      if (part === null) continue;
      const last = parts[parts.length - 1];
      if (typeof part === "object" && last && typeof last === "object") last.jsx += part.jsx;
      else parts.push(part);
    }
    const rendered = parts
      .filter((part) => typeof part === "string" || part.jsx !== "")
      .map((part) => (typeof part === "string" ? part : `text:${JSON.stringify(part.jsx)}`));
    return `(${node.kind} ${rendered.join(" ")})`;
  };
  const tree = shape(source);
  return { ranges: [...found.values()].sort((a, b) => a.pos - b.pos), tree };
}

function shRanges(text) {
  const ranges = [];
  const pending = [];
  const size = text.length;
  let i = 0;
  const skipSingle = () => {
    i += 1;
    while (i < size && text[i] !== "'") i += 1;
    i += 1;
  };
  const skipEscaped = (quote, lead) => {
    i += lead;
    while (i < size && text[i] !== quote) i += text[i] === "\\" ? 2 : 1;
    i += 1;
  };
  const heredocBodies = () => {
    while (pending.length) {
      const { delimiter, dash } = pending.shift();
      while (i < size) {
        let stop = text.indexOf("\n", i);
        if (stop === -1) stop = size;
        const line = dash ? text.slice(i, stop).replace(/^\t+/, "") : text.slice(i, stop);
        i = Math.min(stop + 1, size);
        if (line === delimiter) break;
      }
    }
  };
  const substitution = () => {
    const arithmetic = text[i + 2] === "(";
    i += 2;
    command(true, arithmetic);
  };
  const brace = (quoted) => {
    i += 2;
    while (i < size && text[i] !== "}") {
      const ch = text[i];
      if (ch === "\\") i += 2;
      else if (ch === "'" && !quoted) skipSingle();
      else if (ch === '"') doubleQuoted();
      else if (ch === "`") skipEscaped("`", 1);
      else if (ch === "$" && text[i + 1] === "(") substitution();
      else if (ch === "$" && text[i + 1] === "{") brace(quoted);
      else i += 1;
    }
    i += 1;
  };
  const doubleQuoted = () => {
    i += 1;
    while (i < size && text[i] !== '"') {
      const ch = text[i];
      if (ch === "\\") i += 2;
      else if (ch === "`") skipEscaped("`", 1);
      else if (ch === "$" && text[i + 1] === "(") substitution();
      else if (ch === "$" && text[i + 1] === "{") brace(true);
      else i += 1;
    }
    i += 1;
  };
  const command = (nested, arithmetic) => {
    let depth = 0;
    let wordStart = true;
    while (i < size) {
      const ch = text[i];
      if (ch === "\n") {
        i += 1;
        wordStart = true;
        if (pending.length) heredocBodies();
        continue;
      }
      if (ch === "#" && wordStart) {
        let stop = text.indexOf("\n", i);
        if (stop === -1) stop = size;
        ranges.push({ pos: i, end: stop, text: text.slice(i, stop), maskPos: i, maskEnd: stop });
        i = stop;
        continue;
      }
      wordStart = false;
      if (ch === "\\") i += 2;
      else if (ch === "'") skipSingle();
      else if (ch === '"') doubleQuoted();
      else if (ch === "`") skipEscaped("`", 1);
      else if (ch === "$" && text[i + 1] === "'") skipEscaped("'", 2);
      else if (ch === "$" && text[i + 1] === "(") substitution();
      else if (ch === "$" && text[i + 1] === "{") brace(false);
      else if (ch === "(" && text[i + 1] === "(" && !arithmetic) {
        i += 1;
        command(true, true);
      } else if (ch === "(") {
        depth += 1;
        i += 1;
      } else if (ch === ")") {
        i += 1;
        if (nested && depth === 0) return;
        depth -= 1;
      } else if (ch === "<" && text[i + 1] === "<" && !arithmetic) {
        if (text[i + 2] === "<") {
          i += 3;
          continue;
        }
        const match = /^<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|\\?([A-Za-z_][A-Za-z0-9_]*))/.exec(text.slice(i, i + 200));
        if (match) {
          pending.push({ delimiter: match[2] ?? match[3] ?? match[4], dash: match[1] === "-" });
          i += match[0].length;
        } else i += 2;
      } else {
        wordStart = ch === " " || ch === "\t" || ch === ";" || ch === "|" || ch === "&";
        i += 1;
      }
    }
  };
  command(false, false);
  return ranges;
}

function lineRanges(text, lang) {
  const ranges = [];
  let offset = 0;
  let inBlock = false;
  for (const line of text.split("\n")) {
    const indent = line.length - line.trimStart().length;
    const body = line.trim();
    const push = () => ranges.push({ pos: offset + indent, end: offset + line.length, text: body, maskPos: offset + indent, maskEnd: offset + line.length });
    if (lang === "hash") {
      if (body.startsWith("#")) push();
    } else if (inBlock) {
      push();
      if (body.includes("*/")) inBlock = false;
    } else if (body.startsWith("--")) {
      push();
    } else if (body.startsWith("/*") && !body.startsWith("/*!")) {
      push();
      inBlock = !body.includes("*/");
    }
    offset += line.length + 1;
  }
  return ranges;
}

function scanPython(files, inlineText) {
  if (inlineText !== undefined) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "comment-lint-"));
    const target = path.join(dir, "inline.py");
    fs.writeFileSync(target, inlineText);
    try {
      const raw = execFileSync("python3", [PY_HELPER, "scan"], { input: target, encoding: "utf8" });
      return { [files[0]]: JSON.parse(raw)[target] };
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
  const raw = execFileSync("python3", [PY_HELPER, "scan"], {
    cwd: repoRoot(),
    input: files.join("\n"),
    encoding: "utf8",
    maxBuffer: 1 << 28,
  });
  return JSON.parse(raw);
}

function pythonOffsets(text, comments) {
  const starts = [0];
  for (let index = text.indexOf("\n"); index !== -1; index = text.indexOf("\n", index + 1)) starts.push(index + 1);
  return comments.map((comment) => {
    const lineStart = starts[comment.line - 1];
    let lineEnd = text.indexOf("\n", lineStart);
    if (lineEnd === -1) lineEnd = text.length;
    const prefix = Array.from(text.slice(lineStart, lineEnd)).slice(0, comment.col).join("");
    const pos = lineStart + prefix.length;
    return { pos, end: lineEnd, text: comment.text, maskPos: pos, maskEnd: lineEnd };
  });
}

function inlineMetadataStarts(text) {
  const starts = new Set();
  const lines = text.split("\n");
  const offsets = [];
  let offset = 0;
  for (const line of lines) {
    offsets.push(offset);
    offset += line.length + 1;
  }
  for (let index = 0; index < lines.length; index += 1) {
    if (!/^# \/\/\/ [a-zA-Z0-9-]+$/.test(lines[index])) continue;
    let close = -1;
    let next = index + 1;
    for (; next < lines.length && /^#( .*)?$/.test(lines[next]); next += 1) {
      if (lines[next] === "# ///") close = next;
    }
    if (close === -1) continue;
    for (let line = index; line <= close; line += 1) starts.add(offsets[line]);
    index = close;
  }
  return starts;
}

export async function analyseText(file, text, pythonComments) {
  const lang = languageOf(file);
  let ranges;
  let tree = null;
  if (lang === "ts") {
    const result = tsAnalyse(await loadTypescript(), file, text);
    ranges = result.ranges;
    tree = result.tree;
  } else if (lang === "py") ranges = pythonOffsets(text, pythonComments ?? scanPython([file], text)[file]);
  else if (lang === "sh") ranges = shRanges(text);
  else ranges = lineRanges(text, lang);
  const metadata = lang === "py" ? inlineMetadataStarts(text) : new Set();
  const directive = (range) => metadata.has(range.pos) || isDirective(lang, range.text);
  const directives = ranges.filter(directive);
  ranges = ranges.filter((range) => !directive(range));
  return { lang, text, tree, blocks: toBlocks(file, text, ranges), directives: toBlocks(file, text, directives) };
}

async function analyse(files) {
  const byFile = new Map();
  const pythonFiles = files.filter((file) => languageOf(file) === "py");
  const python = pythonFiles.length ? scanPython(pythonFiles) : {};
  for (const file of files) {
    const text = fs.readFileSync(path.join(repoRoot(), file), "utf8");
    byFile.set(file, await analyseText(file, text, python[file]));
  }
  return byFile;
}

function toBlocks(file, text, ranges) {
  const starts = [0];
  for (let index = text.indexOf("\n"); index !== -1; index = text.indexOf("\n", index + 1)) starts.push(index + 1);
  const lineOf = (offset) => {
    let low = 0;
    let high = starts.length - 1;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (starts[middle] <= offset) low = middle;
      else high = middle - 1;
    }
    return low + 1;
  };
  const blocks = [];
  for (const range of ranges) {
    const start = lineOf(range.pos);
    const end = lineOf(Math.max(range.pos, range.end - 1));
    const lineStart = starts[start - 1];
    let lineEnd = text.indexOf("\n", range.end);
    if (lineEnd === -1) lineEnd = text.length;
    const own = text.slice(lineStart, range.maskPos).trim() === "" && text.slice(range.maskEnd, lineEnd).trim() === "";
    const last = blocks[blocks.length - 1];
    if (last && last.own && own && start === last.end + 1) {
      last.end = end;
      last.text += `\n${range.text}`;
      last.ranges.push(range);
    } else blocks.push({ id: `${file}:${start}`, file, start, end, own, text: range.text, ranges: [range] });
  }
  return blocks;
}

export function countsOf(blocks) {
  const lines = new Set();
  let whole = 0;
  for (const block of blocks) {
    for (let line = block.start; line <= block.end; line += 1) lines.add(line);
    if (block.own) whole += block.end - block.start + 1;
  }
  return { lines: lines.size, whole };
}

export async function stripText(file, text) {
  const entry = await analyseText(file, text);
  const result = removeRanges(text, entry.blocks.flatMap((block) => block.ranges), entry.lang);
  const problem = await equivalent(file, entry.lang, text, result.text, entry.tree);
  return { ...result, problem };
}

function removeRanges(text, ranges, lang) {
  const mask = new Uint8Array(text.length);
  for (const range of ranges) mask.fill(1, range.maskPos, range.maskEnd);
  const hadFinalNewline = text.endsWith("\n");
  const lines = text.split("\n");
  if (hadFinalNewline) lines.pop();
  const opens = lang === "py" ? /[:[({]$/ : /[[({]$/;
  const blank = (line) => line.trim() === "";
  const out = [];
  let offset = 0;
  let gap = false;
  let removed = 0;
  for (const line of lines) {
    const start = offset;
    offset += line.length + 1;
    let touched = false;
    let rest = "";
    for (let index = 0; index < line.length; index += 1) {
      if (!mask[start + index]) {
        rest += line[index];
        continue;
      }
      touched = true;
      while (index + 1 < line.length && mask[start + index + 1]) index += 1;
      if (rest.trim() === "" || /\s$/.test(rest)) {
        while (index + 1 < line.length && !mask[start + index + 1] && /[ \t]/.test(line[index + 1])) index += 1;
      }
    }
    if (touched) rest = rest.trimEnd();
    if (touched && blank(rest)) {
      gap = true;
      removed += 1;
      continue;
    }
    if (gap) {
      const previous = out[out.length - 1];
      if (blank(rest) && (out.length === 0 || blank(previous) || opens.test(previous.trimEnd()))) {
        removed += 1;
        continue;
      }
      if (/^[\])}]/.test(rest.trim())) {
        while (out.length && blank(out[out.length - 1])) {
          out.pop();
          removed += 1;
        }
      }
      gap = false;
    }
    out.push(rest);
  }
  if (gap) {
    while (out.length && blank(out[out.length - 1])) {
      out.pop();
      removed += 1;
    }
  }
  return { text: out.join("\n") + (hadFinalNewline && out.length ? "\n" : ""), removed };
}

let modernBash;
function findModernBash() {
  if (modernBash !== undefined) return modernBash;
  modernBash = null;
  for (const candidate of ["bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"]) {
    const probe = spawnSync(candidate, ["-c", "echo ${BASH_VERSINFO[0]}"], { encoding: "utf8" });
    if (probe.status === 0 && Number(probe.stdout.trim()) >= 5) {
      modernBash = candidate;
      break;
    }
  }
  return modernBash;
}

async function equivalent(file, lang, before, after, beforeTree) {
  if (lang === "ts") {
    const result = tsAnalyse(await loadTypescript(), file, after);
    return result.tree === beforeTree ? null : "syntax tree changed";
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "comment-lint-"));
  const left = path.join(dir, `before${path.extname(file)}`);
  const right = path.join(dir, `after${path.extname(file)}`);
  fs.writeFileSync(left, before);
  fs.writeFileSync(right, after);
  try {
    if (lang === "py") {
      const result = spawnSync("python3", [PY_HELPER, "same-ast", left, right]);
      return result.status === 0 ? null : "python AST changed";
    }
    const bash = findModernBash();
    if (!bash) {
      const result = spawnSync("bash", ["-n", right]);
      return result.status === 0 ? null : "bash -n rejects the result";
    }
    const pretty = (target) => spawnSync(bash, ["--pretty-print", target], { encoding: "utf8", maxBuffer: 1 << 26 });
    const commands = (run) => run.stdout.split("\n").filter((line) => line.trim() !== "").join("\n");
    const a = pretty(left);
    const b = pretty(right);
    if (a.status !== 0) return "bash cannot parse the original";
    return b.status === 0 && commands(a) === commands(b) ? null : "bash parse changed";
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

export function fingerprintsOf(blocks) {
  const prints = [];
  for (const block of blocks) {
    for (const line of block.text.split("\n")) {
      const body = line.trim();
      if (body) prints.push(crypto.createHash("sha1").update(body).digest("hex").slice(0, 8));
    }
  }
  return prints.sort();
}

function readBaseline() {
  if (!fs.existsSync(BASELINE)) return null;
  const stored = JSON.parse(fs.readFileSync(BASELINE, "utf8")).files;
  return Object.fromEntries(Object.entries(stored).map(([file, prints]) => [file, prints.split(" ").filter(Boolean)]));
}

function writeBaseline(files) {
  const names = Object.keys(files).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const rows = names.map((file) => `    ${JSON.stringify(file)}: ${JSON.stringify(files[file].join(" "))}`);
  fs.writeFileSync(BASELINE, `{\n  "version": 2,\n  "files": {\n${rows.join(",\n")}\n  }\n}\n`);
}

async function currentPrints() {
  const analysed = await analyse(trackedFiles([]));
  const prints = {};
  for (const [file, entry] of analysed) {
    const found = fingerprintsOf(entry.blocks);
    if (found.length > 0) prints[file] = found;
  }
  return prints;
}

async function commandScan(selectors, flags) {
  const analysed = await analyse(trackedFiles(selectors));
  const blocks = [];
  for (const entry of analysed.values()) {
    for (const block of flags.has("--directives") ? entry.directives : entry.blocks) {
      blocks.push({ id: block.id, file: block.file, start: block.start, end: block.end, own: block.own, text: block.text });
    }
  }
  fs.writeSync(1, `${JSON.stringify(blocks, null, 1)}\n`);
  return 0;
}

async function commandCount(selectors, flags) {
  const analysed = await analyse(trackedFiles(selectors));
  const totals = {};
  for (const entry of analysed.values()) {
    const { lines, whole } = countsOf(entry.blocks);
    const total = (totals[entry.lang] ??= { files: 0, withComments: 0, lines: 0, whole: 0, blocks: 0, directives: 0, sourceLines: 0 });
    total.files += 1;
    total.withComments += lines > 0 ? 1 : 0;
    total.lines += lines;
    total.whole += whole;
    total.blocks += entry.blocks.length;
    total.directives += entry.directives.length;
    total.sourceLines += entry.text.split("\n").length - (entry.text.endsWith("\n") ? 1 : 0);
  }
  const sum = { files: 0, withComments: 0, lines: 0, whole: 0, blocks: 0, directives: 0, sourceLines: 0 };
  for (const total of Object.values(totals)) for (const key of Object.keys(sum)) sum[key] += total[key];
  totals.total = sum;
  if (flags.has("--json")) fs.writeSync(1, `${JSON.stringify(totals, null, 1)}\n`);
  else console.table(totals);
  return 0;
}

function difference(left, right) {
  const spare = new Map();
  for (const print of right) spare.set(print, (spare.get(print) ?? 0) + 1);
  let extra = 0;
  for (const print of left) {
    const have = spare.get(print) ?? 0;
    if (have > 0) spare.set(print, have - 1);
    else extra += 1;
  }
  return extra;
}

export function compareToBaseline(current, baseline) {
  const added = [];
  const stale = [];
  for (const file of [...new Set([...Object.keys(current), ...Object.keys(baseline)])].sort()) {
    const now = current[file] ?? [];
    const allowed = baseline[file] ?? [];
    const fresh = difference(now, allowed);
    const gone = difference(allowed, now);
    if (fresh > 0) added.push(`  ${file}: ${fresh} comment line${fresh === 1 ? "" : "s"} the baseline does not know`);
    else if (gone > 0) stale.push(`  ${file}: ${gone} comment line${gone === 1 ? "" : "s"} gone, baseline still lists ${allowed.length}`);
  }
  return { added, stale };
}

async function commandCheck() {
  const baseline = readBaseline();
  if (!baseline) {
    console.error(`comment-lint: baseline.json is missing. Run \`${CONFIG.run} baseline --init\`.`);
    return 1;
  }
  const current = await currentPrints();
  const { added, stale } = compareToBaseline(current, baseline);
  if (added.length) {
    console.error(`comment-lint: comments are banned${CONFIG.rule ? ` (${CONFIG.rule})` : ""}. These files have new or reworded ones:`);
    console.error(added.join("\n"));
    console.error(`Delete them.${CONFIG.decisions ? ` A decision goes in ${CONFIG.decisions}.` : ""} A workaround becomes an issue,`);
    console.error(`and anything else belongs in a name, a type or a test. \`${CONFIG.run} scan <file>\` lists them.`);
  }
  if (stale.length) {
    console.error("comment-lint: these files lost comments, so the baseline has to come down with them:");
    console.error(stale.join("\n"));
    console.error(`Run \`${CONFIG.run} baseline\` and commit baseline.json.`);
  }
  if (added.length || stale.length) return 1;
  const remaining = Object.values(current).reduce((total, prints) => total + prints.length, 0);
  console.log(`comment-lint: ok, ${remaining} comment lines left in ${Object.keys(current).length} files`);
  return 0;
}

async function commandBaseline(flags) {
  const current = await currentPrints();
  const baseline = readBaseline();
  if (!baseline) {
    if (!flags.has("--init")) {
      console.error("comment-lint: no baseline yet. Pass --init to create the first one.");
      return 1;
    }
    writeBaseline(current);
    console.log(`comment-lint: baseline created for ${Object.keys(current).length} files`);
    return 0;
  }
  const { added } = compareToBaseline(current, baseline);
  if (added.length) {
    console.error("comment-lint: the baseline only goes down. These files have comments it does not list:");
    console.error(added.join("\n"));
    return 1;
  }
  writeBaseline(current);
  const size = (files) => Object.values(files).reduce((total, prints) => total + prints.length, 0);
  console.log(`comment-lint: baseline lowered from ${size(baseline)} to ${size(current)} comment lines`);
  return 0;
}

async function commandStrip(selectors, flags, options) {
  const files = trackedFiles(selectors);
  const only = options.ids ? new Set(JSON.parse(fs.readFileSync(options.ids, "utf8"))) : null;
  const dryRun = flags.has("--dry-run");
  const analysed = await analyse(files);
  let failures = 0;
  let removedTotal = 0;
  let touched = 0;
  for (const [file, entry] of analysed) {
    if (!STRIPPABLE.has(entry.lang)) continue;
    const blocks = only ? entry.blocks.filter((block) => only.has(block.id)) : entry.blocks;
    if (blocks.length === 0) continue;
    const ranges = blocks.flatMap((block) => block.ranges);
    const result = removeRanges(entry.text, ranges, entry.lang);
    const problem = await equivalent(file, entry.lang, entry.text, result.text, entry.tree);
    if (problem) {
      failures += 1;
      console.error(`SKIP ${file}: ${problem}`);
      continue;
    }
    if (!dryRun) fs.writeFileSync(path.join(repoRoot(), file), result.text);
    removedTotal += result.removed;
    touched += 1;
    console.log(`${String(result.removed).padStart(5)}  ${file}`);
  }
  console.log(`comment-lint: ${dryRun ? "would remove" : "removed"} ${removedTotal} lines from ${touched} files, ${failures} skipped`);
  return failures ? 1 : 0;
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const flags = new Set();
  const options = {};
  const selectors = [];
  for (let index = 0; index < rest.length; index += 1) {
    if (rest[index] === "--ids") options.ids = rest[(index += 1)];
    else if (rest[index].startsWith("--")) flags.add(rest[index]);
    else selectors.push(rest[index]);
  }
  if (command === "scan") return commandScan(selectors, flags);
  if (command === "count") return commandCount(selectors, flags);
  if (command === "check") return commandCheck();
  if (command === "baseline") return commandBaseline(flags);
  if (command === "strip") {
    if (selectors.length === 0) {
      console.error("comment-lint: strip needs at least one file or directory.");
      return 2;
    }
    return commandStrip(selectors, flags, options);
  }
  console.error("usage: comments.mjs scan|count|check|baseline|strip [paths] [--directives] [--json] [--ids file.json] [--dry-run] [--init]");
  return 2;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
