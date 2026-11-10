#!/usr/bin/env node
// /landing-page capture-refs: every reference page captured in one call, four at a time, so the agent spends the reference
// step on judging pages instead of writing a browser script per site.
//   refs/<id>/w<width>-00.png   the first viewport per width, a fresh context each (no saved logins or cookies), JavaScript on
//   refs/<id>/capture.json      {id, url, status: ok|challenge|failed, title, http_status, captures, reason?, video?}
//   refs/<id>/rec.webm          with record: true — the page scrolled and pointed at for about nine seconds
//   refs/capture-refs.json      the index of this call;  refs/record.done  written when every recording has finished
// A Cloudflare or bot check is reported as challenge: the agent reopens that page in a real browser tab (direction.md, References).
// --phase stills|record|all picks what runs; the runner starts the record phase detached when asked to (--background).
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { launchBrowser } from "./landing-browser.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
if (!args.work || !args.file) {
  console.error("usage: landing-capture-refs.mjs --work DIR --file refs-to-capture.json [--phase stills|record|all] [--concurrency 4]");
  process.exit(2);
}
const work = resolve(args.work);
const phase = args.phase ?? "all";
const concurrency = Math.max(1, Number(args.concurrency ?? 4));
const recordSeconds = Number(args["record-seconds"] ?? process.env.LANDING_RECORD_SECONDS ?? 9);
const refsDir = join(work, "refs");
mkdirSync(refsDir, { recursive: true });

let list;
try {
  list = JSON.parse(readFileSync(resolve(args.file), "utf8"));
} catch (e) {
  console.error(`landing-capture-refs: ${args.file} is not valid JSON (${e.message})`);
  process.exit(2);
}
const bad = [];
if (!Array.isArray(list)) bad.push("must be an array of {id, url, widths?, record?}");
else
  for (const r of list) {
    if (typeof r?.id !== "string" || !/^[A-Za-z0-9._-]+$/.test(r.id)) bad.push(`id ${JSON.stringify(r?.id)} may hold letters, digits, dot, dash, underscore`);
    if (typeof r?.url !== "string" || !/^https?:\/\//.test(r.url)) bad.push(`${r?.id ?? "?"}: url must be http(s)`);
    if (r?.widths != null && !(Array.isArray(r.widths) && r.widths.length && r.widths.every((w) => Number.isInteger(w) && w >= 200 && w <= 3000)))
      bad.push(`${r?.id ?? "?"}: widths are pixel numbers`);
  }
if (Array.isArray(list) && new Set(list.map((r) => r?.id)).size !== list.length) bad.push("ids must be unique");
if (bad.length) {
  console.error(`landing-capture-refs: ${bad.join("; ")}`);
  process.exit(2);
}

const heightFor = (w) => (w <= 430 ? 844 : w <= 900 ? 1024 : 900);
const CHALLENGE_TITLE = /just a moment|attention required|checking your (browser|connection)|verify(ing)? you are (a )?human|are you a robot|access denied|security check|잠시만 기다리|보안 확인/i;
const CHALLENGE_TEXT = /checking (if the site connection is secure|your browser)|verify you are human|enable javascript and cookies to continue|press (&|and) hold|ddos protection by|performance (&|and) security by cloudflare|captcha/i;
const capturePath = (id) => join(refsDir, id, "capture.json");
const readCapture = (id) => (existsSync(capturePath(id)) ? JSON.parse(readFileSync(capturePath(id), "utf8")) : {});
const writeCapture = (id, obj) => writeFileSync(capturePath(id), JSON.stringify(obj, null, 2) + "\n");

async function pool(items, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  });
  await Promise.all(workers);
  return results;
}

async function challengeOf(page, response) {
  const title = await page.title().catch(() => "");
  const signs = await page
    .evaluate(() => ({
      text: (document.body?.innerText ?? "").slice(0, 4000),
      frames: [...document.querySelectorAll("iframe")].map((f) => f.src).join(" "),
      cf: !!document.querySelector("#challenge-form, #cf-challenge-running, .cf-browser-verification, #challenge-stage, [data-sitekey]"),
    }))
    .catch(() => ({ text: "", frames: "", cf: false }));
  const server = (response?.headers()?.server ?? "").toLowerCase();
  const status = response?.status() ?? 0;
  const hit =
    CHALLENGE_TITLE.test(title) ||
    CHALLENGE_TEXT.test(signs.text) ||
    signs.cf ||
    /challenges\.cloudflare\.com|hcaptcha\.com|recaptcha/.test(signs.frames) ||
    ((status === 403 || status === 503) && server.includes("cloudflare"));
  return { title, hit, status };
}

async function stills(browser, ref) {
  const dir = join(refsDir, ref.id);
  mkdirSync(dir, { recursive: true });
  const widths = ref.widths ?? [1440, 390];
  const entry = { id: ref.id, url: ref.url, status: "ok", title: "", http_status: null, widths, captures: [], errors: [] };
  const started = Date.now();
  for (const w of widths) {
    const ctx = await browser.newContext({ viewport: { width: w, height: heightFor(w) }, deviceScaleFactor: 1 });
    try {
      const page = await ctx.newPage();
      // A page whose last tracker never finishes loading is still captured once it has drawn.
      const response = await page.goto(ref.url, { waitUntil: "domcontentloaded", timeout: 30000 });
      await page.waitForLoadState("load", { timeout: 10000 }).catch(() => {});
      await page.waitForLoadState("networkidle", { timeout: 4000 }).catch(() => {});
      await page.waitForTimeout(800);
      const ch = await challengeOf(page, response);
      entry.title ||= ch.title;
      entry.http_status ??= ch.status;
      const f = `w${w}-00.png`;
      await page.screenshot({ path: join(dir, f) });
      entry.captures.push(`refs/${ref.id}/${f}`);
      if (ch.hit) {
        entry.status = "challenge";
        entry.reason = `bot check (${ch.title || `HTTP ${ch.status}`}); reopen it in a real browser tab`;
        break;
      }
    } catch (e) {
      entry.errors.push(`${w}: ${String(e.message).split("\n")[0].slice(0, 200)}`);
    } finally {
      await ctx.close().catch(() => {});
    }
  }
  if (entry.status === "ok" && entry.captures.length === 0) {
    entry.status = "failed";
    entry.reason = entry.errors[0] ?? "no capture";
  }
  entry.seconds = Math.round((Date.now() - started) / 100) / 10;
  const prev = readCapture(ref.id);
  writeCapture(ref.id, { ...entry, ...(prev.video ? { video: prev.video } : {}) });
  return entry;
}

// The page scrolled down and back with the pointer moving across it: a still cannot show what answers the visitor.
async function record(browser, ref) {
  const dir = join(refsDir, ref.id);
  const tmp = join(dir, "rec-tmp");
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(tmp, { recursive: true });
  const size = { width: 1440, height: 900 };
  const result = { id: ref.id, record: "failed" };
  const ctx = await browser.newContext({ viewport: size, deviceScaleFactor: 1, recordVideo: { dir: tmp, size } });
  try {
    const page = await ctx.newPage();
    await page.goto(ref.url, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForLoadState("load", { timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(600);
    const steps = Math.max(8, Math.round(recordSeconds * 4));
    const end = Date.now() + recordSeconds * 1000;
    for (let i = 0; i < steps && Date.now() < end; i++) {
      const t = i / steps;
      await page.mouse.move(200 + Math.round(1000 * Math.abs(Math.sin(t * Math.PI * 2))), 200 + Math.round(400 * t), { steps: 4 });
      await page.mouse.wheel(0, i < steps * 0.7 ? 450 : -900);
      await page.waitForTimeout(200);
    }
    result.record = "ok";
  } catch (e) {
    result.reason = String(e.message).split("\n")[0].slice(0, 200);
  }
  await ctx.close().catch(() => {});
  const made = readdirSync(tmp).find((f) => f.endsWith(".webm"));
  if (made) {
    renameSync(join(tmp, made), join(dir, "rec.webm"));
    result.video = `refs/${ref.id}/rec.webm`;
    if (result.record === "failed") result.record = "partial";
  }
  rmSync(tmp, { recursive: true, force: true });
  const prev = readCapture(ref.id);
  writeCapture(ref.id, { ...prev, id: ref.id, url: ref.url, record: result.record, ...(result.video ? { video: result.video } : {}), ...(result.reason ? { record_reason: result.reason } : {}) });
  return result;
}

const started = Date.now();
const { browser, reason } = await launchBrowser();
if (!browser) {
  const summary = { result: "unverified", reason, refs: [] };
  writeFileSync(join(refsDir, "capture-refs.json"), JSON.stringify(summary, null, 2) + "\n");
  if (phase !== "stills") writeFileSync(join(refsDir, "record.done"), JSON.stringify({ result: "unverified", reason }) + "\n");
  console.log(JSON.stringify(summary));
  process.exit(0);
}
const summary = { concurrency, refs: [] };
if (phase === "stills" || phase === "all") {
  const done = await pool(list, (ref) => stills(browser, ref));
  summary.refs = done.map(({ id, status, title, captures, reason: why }) => ({ id, status, title, captures, ...(why ? { reason: why } : {}) }));
  summary.seconds = Math.round((Date.now() - started) / 100) / 10;
  summary.result = done.every((d) => d.status === "ok") ? "done" : "partial";
  writeFileSync(join(refsDir, "capture-refs.json"), JSON.stringify(summary, null, 2) + "\n");
}
if (phase === "record" || phase === "all") {
  rmSync(join(refsDir, "record.done"), { force: true });
  const recs = await pool(
    list.filter((r) => r.record),
    (ref) => record(browser, ref),
  );
  summary.recordings = recs;
  writeFileSync(join(refsDir, "record.done"), JSON.stringify({ result: recs.every((r) => r.record === "ok") ? "done" : "partial", seconds: Math.round((Date.now() - started) / 100) / 10, recordings: recs }, null, 2) + "\n");
}
await browser.close();
console.log(JSON.stringify(summary));
