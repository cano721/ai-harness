#!/usr/bin/env node
// /landing-page operate: run a reviewer's interaction script against the served page, so the reviewer never hunts for
// Playwright or writes files outside the work folder. The script is an ES module whose default export receives
//   { page, shot(name), log(...values), width, height }
// shot() saves <out>/<name>.png and returns its path; log() lines and the shots land in <out>/operate.json.
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { launchBrowser } from "./landing-browser.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
if (!args.url || !args.script || !args.out) {
  console.error("usage: landing-operate.mjs --url URL --script FILE.mjs --out DIR [--width 1440] [--height 900]");
  process.exit(2);
}
const out = args.out;
mkdirSync(out, { recursive: true });
const width = Number(args.width ?? 1440);
const height = Number(args.height ?? (width <= 430 ? 844 : 900));
const report = { url: args.url, script: resolve(args.script), width, height, shots: [], log: [], errors: [] };
const finish = (result, extra = {}) => {
  writeFileSync(join(out, "operate.json"), JSON.stringify({ ...report, result, ...extra }, null, 2) + "\n");
  console.log(JSON.stringify({ result, out, shots: report.shots, log: report.log, errors: report.errors, ...extra }));
};

const { browser, reason } = await launchBrowser();
if (!browser) {
  finish("unverified", { reason });
  process.exit(0);
}
try {
  const mod = await import(pathToFileURL(resolve(args.script)).href);
  if (typeof mod.default !== "function") throw new Error("the script must `export default async ({ page, shot, log }) => { ... }`");
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, hasTouch: width <= 430 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(8000);
  page.on("pageerror", (e) => report.errors.push(e.message));
  await page.goto(args.url, { waitUntil: "load", timeout: 30000 });
  await page.waitForTimeout(1200);
  const shot = async (name) => {
    if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error(`shot name '${name}' may hold letters, digits, dot, dash, underscore`);
    const file = join(out, `${name}.png`);
    await page.screenshot({ path: file });
    report.shots.push(file);
    return file;
  };
  const log = (...values) => report.log.push(values.map((v) => (typeof v === "string" ? v : JSON.stringify(v))).join(" "));
  await mod.default({ page, shot, log, width, height });
  finish("done");
} catch (e) {
  report.errors.push(String(e?.stack ?? e));
  finish("failed");
} finally {
  await browser.close();
}
