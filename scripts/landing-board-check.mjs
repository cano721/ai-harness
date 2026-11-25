#!/usr/bin/env node
// Board check (#529): open a reference or draft board in a real browser, click every tab, and confirm each image and
// video in that tab actually loads. A capture tour of the first tab cannot see a 404 image on another tab.
//   --work DIR  serve DIR read-only on 127.0.0.1 (random port) and open board.html — works with or without the Harness Board
//   --url URL   open a board that is already served
//   <out>/tab-<kind>.png   each tab, full page;   <out>/board-check.json   {url, result, reason?, tabs, errors}
// Exit: 0 pass or unverified (no browser), 4 fail, 2 usage.
import { createReadStream, existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, resolve, sep } from "node:path";
import { launchBrowser } from "./landing-browser.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
if ((!args.work && !args.url) || (args.work && args.url) || !args.out) {
  console.error("usage: landing-board-check.mjs (--work DIR | --url URL) --out DIR [--width 1440]");
  process.exit(2);
}
const out = args.out;
const width = Number(args.width ?? 1440);
const WAIT_MS = 10000;
const TYPES = {
  ".html": "text/html; charset=utf-8", ".json": "application/json", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
  ".webp": "image/webp", ".avif": "image/avif", ".svg": "image/svg+xml", ".mp4": "video/mp4", ".webm": "video/webm",
  ".mov": "video/quicktime",
};

// Read-only static server for the work folder. Paths that leave the folder are refused.
function serve(dir) {
  const root = resolve(dir);
  const server = createServer((req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") return res.writeHead(405).end();
    let rel;
    try {
      rel = decodeURIComponent(new URL(req.url, "http://x").pathname);
    } catch {
      return res.writeHead(400).end();
    }
    const file = resolve(root, "." + rel);
    if (rel.split("/").includes("..") || (file !== root && !file.startsWith(root + sep))) return res.writeHead(403).end();
    let st;
    try {
      st = statSync(file);
    } catch {
      return res.writeHead(404).end();
    }
    if (!st.isFile()) return res.writeHead(404).end();
    const type = TYPES[extname(file).toLowerCase()] ?? "application/octet-stream";
    const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
    if (m && (m[1] || m[2])) {
      const start = m[1] ? Number(m[1]) : Math.max(0, st.size - Number(m[2]));
      const end = m[1] && m[2] ? Math.min(Number(m[2]), st.size - 1) : st.size - 1;
      if (start > end || start >= st.size) return res.writeHead(416, { "Content-Range": `bytes */${st.size}` }).end();
      res.writeHead(206, { "Content-Type": type, "Content-Length": end - start + 1, "Content-Range": `bytes ${start}-${end}/${st.size}`, "Accept-Ranges": "bytes" });
      return req.method === "HEAD" ? res.end() : createReadStream(file, { start, end }).pipe(res);
    }
    res.writeHead(200, { "Content-Type": type, "Content-Length": st.size, "Accept-Ranges": "bytes" });
    return req.method === "HEAD" ? res.end() : createReadStream(file).pipe(res);
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok(server)));
}

// In the page: wait for every image and video in one panel, then report what did not load.
async function checkPanel(panel, waitMs) {
  const until = (el, events, done) =>
    done()
      ? Promise.resolve()
      : new Promise((ok) => {
          const t = setTimeout(ok, waitMs);
          for (const e of events) el.addEventListener(e, () => (clearTimeout(t), ok()), { once: true });
        });
  const imgs = [...panel.querySelectorAll("img")];
  const videos = [...panel.querySelectorAll("video")];
  for (const i of imgs) i.loading = "eager";
  for (const v of videos) if (v.readyState === 0 && !v.error) v.load();
  await Promise.all([
    ...imgs.map((i) => until(i, ["load", "error"], () => i.complete)),
    ...videos.map((v) => until(v, ["loadedmetadata", "error"], () => v.readyState >= 1 || !!v.error)),
  ]);
  const failed = [];
  for (const i of imgs) {
    const src = i.currentSrc || i.getAttribute("src") || "";
    if (!i.complete) failed.push({ tag: "img", src, why: `not loaded in ${waitMs / 1000}s` });
    else if (i.naturalWidth === 0) failed.push({ tag: "img", src, why: "failed to load" });
  }
  for (const v of videos) {
    const src = v.currentSrc || v.getAttribute("src") || "";
    if (v.error) failed.push({ tag: "video", src, why: `error ${v.error.code}${v.error.message ? `: ${v.error.message}` : ""}` });
    else if (v.readyState === 0) failed.push({ tag: "video", src, why: `no data in ${waitMs / 1000}s` });
  }
  return { images: imgs.length, videos: videos.length, failed };
}

mkdirSync(out, { recursive: true });
const report = { url: args.url ?? null, result: "pass", tabs: [], errors: [] };
const finish = (code) => {
  writeFileSync(join(out, "board-check.json"), JSON.stringify(report, null, 2) + "\n");
  const failed = report.tabs.reduce((n, t) => n + t.failed.length, 0);
  console.log(JSON.stringify({ result: report.result, out, failed }));
  process.exit(code);
};

let server = null;
if (args.work) {
  if (!existsSync(join(args.work, "board.html"))) {
    console.error(`landing-board-check: no board.html in ${args.work}`);
    process.exit(2);
  }
  server = await serve(args.work);
  report.url = `http://127.0.0.1:${server.address().port}/board.html`;
}

const { browser, reason } = await launchBrowser();
if (!browser) {
  server?.close();
  report.result = "unverified";
  report.reason = reason;
  finish(0);
}

try {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 1 });
  const p = await ctx.newPage();
  p.on("pageerror", (e) => report.errors.push(e.message));
  await p.goto(report.url, { waitUntil: "load", timeout: 30000 });
  const tabs = await p.$$eval("nav button[data-tab]", (bs) => bs.map((b) => b.dataset.tab));
  if (!tabs.length) {
    report.result = "fail";
    report.reason = "no tabs (nav button[data-tab]) on the page";
  }
  for (const tab of tabs) {
    await p.click(`nav button[data-tab="${tab}"]`);
    await p.waitForTimeout(200);
    const panel = await p.$(`#tab-${tab}`);
    const res = panel
      ? await panel.evaluate(checkPanel, WAIT_MS)
      : { images: 0, videos: 0, failed: [{ tag: "panel", src: `#tab-${tab}`, why: "tab panel not found" }] };
    const shot = `tab-${tab}.png`;
    await p.screenshot({ path: join(out, shot), fullPage: true });
    report.tabs.push({ tab, shot, ...res });
  }
  await ctx.close();
} catch (e) {
  report.result = "fail";
  report.reason = String(e.message).split("\n")[0];
}
await browser.close();
server?.close();
if (report.tabs.some((t) => t.failed.length)) report.result = "fail";
finish(report.result === "fail" ? 4 : 0);
