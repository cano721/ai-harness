#!/usr/bin/env node
// /landing-page capture: one set of captures every node shares, so neither the maker nor the reviewer writes browser scripts.
//   <out>/w<width>-<nn>.png   a scroll tour, one frame per viewport height, scrolled by wheel (scroll scenes play as a visitor sees them)
//   <out>/rm-<width>.png      first viewport under reduced motion;  <out>/nojs-<width>.png  first viewport with JavaScript off
//   <out>/sheet-<width>.png   the tour on one contact sheet;          <out>/captures.json     the index
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser } from "./landing-browser.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
if (!args.url || !args.out) {
  console.error("usage: landing-capture.mjs --url URL --out DIR [--widths 1440,390] [--max-frames 16]");
  process.exit(2);
}
const out = args.out;
mkdirSync(out, { recursive: true });
const widths = (args.widths ?? "1440,390").split(",").map(Number);
const maxFrames = Number(args["max-frames"] ?? 16);
const heightFor = (w) => (w <= 430 ? 844 : w <= 900 ? 1024 : 900);
const index = { url: args.url, widths: {}, errors: [] };

const { browser, reason } = await launchBrowser();
if (!browser) {
  writeFileSync(join(out, "captures.json"), JSON.stringify({ ...index, result: "unverified", reason }, null, 2) + "\n");
  process.exit(0);
}

async function page(w, opts = {}) {
  const ctx = await browser.newContext({ viewport: { width: w, height: heightFor(w) }, deviceScaleFactor: 1, ...opts });
  const p = await ctx.newPage();
  p.on("pageerror", (e) => index.errors.push(`${w}: ${e.message}`));
  await p.goto(args.url, { waitUntil: "load", timeout: 30000 });
  await p.waitForTimeout(1500);
  return { ctx, p };
}

for (const w of widths) {
  const h = heightFor(w);
  const entry = { tour: [], reduced_motion: null, js_off: null, sheet: null };
  try {
    const { ctx, p } = await page(w);
    const total = await p.evaluate(() => document.documentElement.scrollHeight);
    for (let i = 0; i < maxFrames; i++) {
      if (i > 0) {
        await p.mouse.wheel(0, h);
        await p.waitForTimeout(900);
      }
      const f = `w${w}-${String(i).padStart(2, "0")}.png`;
      await p.screenshot({ path: join(out, f) });
      entry.tour.push(f);
      const y = await p.evaluate(() => scrollY + innerHeight);
      if (y >= (await p.evaluate(() => document.documentElement.scrollHeight)) - 2) break;
    }
    entry.page_height = total;
    await ctx.close();
    for (const [key, opts, f] of [
      ["reduced_motion", { reducedMotion: "reduce" }, `rm-${w}.png`],
      ["js_off", { javaScriptEnabled: false }, `nojs-${w}.png`],
    ]) {
      const s = await page(w, opts);
      await s.p.screenshot({ path: join(out, f) });
      entry[key] = f;
      await s.ctx.close();
    }
    // Contact sheet: the tour frames side by side, scaled down, in reading order.
    const cols = w <= 430 ? 8 : 4;
    const scale = w <= 430 ? 0.5 : 0.35;
    const imgs = entry.tour
      .map((f) => `<img src="data:image/png;base64,${readFileSync(join(out, f)).toString("base64")}">`)
      .join("");
    const sheetW = Math.round(w * scale) * cols + 8 * (cols + 1);
    const sctx = await browser.newContext({ viewport: { width: sheetW, height: 400 }, deviceScaleFactor: 1 });
    const sp = await sctx.newPage();
    await sp.setContent(
      `<style>body{margin:0;padding:8px;background:#888;display:grid;grid-template-columns:repeat(${cols},${Math.round(w * scale)}px);gap:8px}img{width:100%;display:block}</style>${imgs}`,
    );
    await sp.waitForTimeout(300);
    entry.sheet = `sheet-${w}.png`;
    await sp.screenshot({ path: join(out, entry.sheet), fullPage: true });
    await sctx.close();
  } catch (e) {
    index.errors.push(`${w}: ${String(e.message).split("\n")[0]}`);
  }
  index.widths[w] = entry;
}
await browser.close();
index.result = Object.values(index.widths).every((e) => e.sheet) ? "done" : "partial";
writeFileSync(join(out, "captures.json"), JSON.stringify(index, null, 2) + "\n");
console.log(JSON.stringify({ result: index.result, out }));
