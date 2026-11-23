import assert from "node:assert/strict";
import { test } from "node:test";

import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

import { analyseText, compareToBaseline, countsOf, excludePattern, fingerprintsOf, stripText } from "./comments.mjs";

function hasTypescript() {
  try {
    createRequire(`${process.cwd()}/package.json`).resolve("typescript");
    return true;
  } catch {
    return false;
  }
}

const noTypescript = hasTypescript() ? false : "the typescript package is not installed";
const noPython = spawnSync("python3", ["--version"]).status === 0 ? false : "python3 is not installed";

const SLASHES = "/" + "/";
const OPEN = "/" + "*";
const CLOSE = "*" + "/";
const HASH = "#";

async function commentTexts(file, text) {
  const entry = await analyseText(file, text);
  return entry.blocks.map((block) => block.text);
}

test("typescript: only real comments are found", { skip: noTypescript }, async () => {
  const text = [
    `const url = "https:${SLASHES}example.test/a";`,
    `const tpl = \`${SLASHES} not one \${1 ${OPEN} inner ${CLOSE} + 1}\`;`,
    "const re = /\\/\\*x/;",
    `${SLASHES} leading note`,
    `const a = 1; ${SLASHES} trailing note`,
    "",
  ].join("\n");
  assert.deepEqual(await commentTexts("a.ts", text), [`${OPEN} inner ${CLOSE}`, `${SLASHES} leading note`, `${SLASHES} trailing note`]);
});

test("typescript: directives are not comments", { skip: noTypescript }, async () => {
  const text = [`${SLASHES} @ts-expect-error wrong on purpose`, "const a: number = 'x';", `${SLASHES} eslint-disable-next-line no-console`, "console.log(a);", ""].join("\n");
  assert.deepEqual(await commentTexts("a.ts", text), []);
});

test("tsx: text that looks like a comment is kept, an empty expression is removed", { skip: noTypescript }, async () => {
  const text = ["export const A = () => (", "  <p>", `    see http:${SLASHES}x.test ${SLASHES} here`, `    {${OPEN} gone ${CLOSE}}`, "    <b>ok</b>", "  </p>", ");", ""].join("\n");
  assert.deepEqual(await commentTexts("a.tsx", text), [`${OPEN} gone ${CLOSE}`]);
  const stripped = await stripText("a.tsx", text);
  assert.equal(stripped.problem, null);
  assert.ok(!stripped.text.includes("gone"));
  assert.ok(stripped.text.includes(`${SLASHES} here`));
});

test("typescript: stripping keeps the syntax tree and tidies blank lines", { skip: noTypescript }, async () => {
  const text = ["function f() {", `  ${SLASHES} why`, "", "  const a = 1;", "", `  ${SLASHES} last`, "}", ""].join("\n");
  const stripped = await stripText("a.ts", text);
  assert.equal(stripped.problem, null);
  assert.equal(stripped.text, "function f() {\n  const a = 1;\n}\n");
});

test("python: strings and directives survive", { skip: noPython }, async () => {
  const text = [`${HASH}!/usr/bin/env python3`, `x = "${HASH} not one"  ${HASH} trailing`, `import os  ${HASH} noqa: F401`, `${HASH} own line`, "y = 1", ""].join("\n");
  assert.deepEqual(await commentTexts("a.py", text), [`${HASH} trailing`, `${HASH} own line`]);
  const stripped = await stripText("a.py", text);
  assert.equal(stripped.problem, null);
  assert.equal(stripped.text, `${HASH}!/usr/bin/env python3\nx = "${HASH} not one"\nimport os  ${HASH} noqa: F401\ny = 1\n`);
});

test("shell: heredocs, parameter expansion and quotes are not comments", async () => {
  const text = [
    `${HASH}!/usr/bin/env bash`,
    `${HASH} real`,
    `n=\${${HASH}items[@]}; echo "$${HASH} a ${HASH} b" ${HASH} trailing`,
    "cat <<EOF",
    `${HASH} heredoc body`,
    "EOF",
    `x=$(( 1 << 2 ))`,
    `${HASH} after arithmetic`,
    "",
  ].join("\n");
  assert.deepEqual(await commentTexts("a.sh", text), [`${HASH} real`, `${HASH} trailing`, `${HASH} after arithmetic`]);
  const stripped = await stripText("a.sh", text);
  assert.equal(stripped.problem, null);
  assert.ok(stripped.text.includes(`${HASH} heredoc body`));
});

test("config and sql files are counted by line", async () => {
  const yaml = ["name: x", `${HASH} one`, `  ${HASH} two`, `key: "a ${HASH} b"`, ""].join("\n");
  assert.equal(countsOf((await analyseText("a.yml", yaml)).blocks).lines, 2);
  const docker = [`${HASH} syntax=docker/dockerfile:1`, "FROM scratch", `${HASH} note`, ""].join("\n");
  assert.equal(countsOf((await analyseText("Dockerfile.x", docker)).blocks).lines, 1);
  const sql = ["-- one", "SELECT 1;", `${OPEN}!40101 SET NAMES utf8 ${CLOSE};`, OPEN, "two", CLOSE, ""].join("\n");
  assert.equal(countsOf((await analyseText("a.sql", sql)).blocks).lines, 4);
});

test("the ratchet rejects a new line, a reworded line and a stale baseline", () => {
  assert.deepEqual(compareToBaseline({ "a.ts": ["aa", "bb"] }, { "a.ts": ["aa", "bb"] }), { added: [], stale: [] });
  assert.equal(compareToBaseline({ "a.ts": ["aa", "bb", "cc"] }, { "a.ts": ["aa", "bb"] }).added.length, 1);
  assert.equal(compareToBaseline({ "a.ts": ["aa", "zz"] }, { "a.ts": ["aa", "bb"] }).added.length, 1);
  assert.equal(compareToBaseline({ "a.ts": ["aa", "aa"] }, { "a.ts": ["aa"] }).added.length, 1);
  assert.equal(compareToBaseline({ "new.ts": ["aa"] }, {}).added.length, 1);
  assert.equal(compareToBaseline({ "a.ts": ["aa"] }, { "a.ts": ["aa", "bb"] }).stale.length, 1);
  assert.equal(compareToBaseline({}, { "gone.ts": ["aa"] }).stale.length, 1);
});

test("a fingerprint follows the comment text and ignores where it sits", async () => {
  const one = fingerprintsOf((await analyseText("a.sh", `echo 1\n${HASH} keep me\n`)).blocks);
  const moved = fingerprintsOf((await analyseText("a.sh", `${HASH} keep me\necho 1\necho 2\n`)).blocks);
  const reworded = fingerprintsOf((await analyseText("a.sh", `echo 1\n${HASH} keep you\n`)).blocks);
  assert.deepEqual(one, moved);
  assert.notDeepEqual(one, reworded);
});

test("exclude entries are prefixes or globs", () => {
  assert.ok(excludePattern("docs/").test("docs/a.md"));
  assert.ok(!excludePattern("docs/").test("src/docs/a.ts"));
  assert.ok(excludePattern("**/generated/").test("src/x/generated/a.ts"));
  assert.ok(excludePattern("**/generated/").test("generated/a.ts"));
  assert.ok(excludePattern("src/*.gen.ts").test("src/api.gen.ts"));
  assert.ok(!excludePattern("src/*.gen.ts").test("src/deep/api.gen.ts"));
});
