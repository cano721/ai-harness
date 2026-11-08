#!/usr/bin/env node
// /landing-page measure node. Called by landing-run.sh; writes one JSON result:
//   {result: "pass"|"fail"|"unverified", reason?, title, checks: [{id, status, detail}], moments: [...], needs_input: [...]}
// Measured here, not judged by a model: overflow per width (JS on and off), console/request errors, fake destinations,
// visible placeholders, the main action in the first viewport, content kept with JS off and reduced motion,
// text contrast on solid backgrounds, and the first-run frame rate of every element marked data-moment.
import { createRequire } from "node:module";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
const out = args.out;
if (!args.url || !out) {
  console.error("usage: landing-measure.mjs --url URL --out FILE [--graph FILE] [--motion-level calm|lively|showpiece]");
  process.exit(2);
}
const write = (obj) => writeFileSync(out, JSON.stringify(obj, null, 2) + "\n");
const graph = args.graph && existsSync(args.graph) ? JSON.parse(readFileSync(args.graph, "utf8")) : {};
const cfg = graph.measure ?? {
  widths: [1440, 768, 390, 320],
  moments: {
    desktop: { width: 1440, cpu_throttle: 1, min_fps: 50, max_frame_ms: 100 },
    phone: { width: 390, cpu_throttle: 4, min_fps: 30, max_frame_ms: 200, lite_tier_passes: true },
  },
  js_off_text_ratio: 0.9,
  reduced_motion_text_ratio: 0.95,
};
const level = (args["motion-level"] ?? "calm").toLowerCase();

// Every Playwright install on the machine, in order; the first whose Chromium starts is used.
function playwrightCandidates() {
  const tries = [];
  if (process.env.LANDING_PLAYWRIGHT) tries.push(process.env.LANDING_PLAYWRIGHT);
  tries.push("playwright");
  const npx = join(homedir(), ".npm", "_npx");
  if (existsSync(npx)) {
    for (const d of readdirSync(npx)) {
      const p = join(npx, d, "node_modules", "playwright");
      if (existsSync(join(p, "package.json"))) tries.push(p);
    }
  }
  return tries;
}

const req = createRequire(import.meta.url);
let browser;
const launchErrors = [];
for (const t of playwrightCandidates()) {
  let pw;
  try {
    pw = req(t);
  } catch {
    continue;
  }
  try {
    browser = await pw.chromium.launch();
    break;
  } catch (e) {
    launchErrors.push(`${t}: ${String(e.message).split("\n")[0].slice(0, 160)}`);
  }
}
if (!browser) {
  write({
    result: "unverified",
    reason: launchErrors.length
      ? "No Playwright install could start Chromium"
      : "Playwright not found (set LANDING_PLAYWRIGHT to its module path, or install it with the user's approval)",
    tried: launchErrors,
    checks: [],
  });
  process.exit(0);
}

const checks = [];
const add = (id, ok, detail) => checks.push({ id, status: ok === null ? "unverified" : ok ? "pass" : "fail", detail });
const needsInput = [];

async function open({ width, height = 900, js = true, reduced = false, throttle = 1, init } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, javaScriptEnabled: js, reducedMotion: reduced ? "reduce" : "no-preference" });
  const page = await ctx.newPage();
  if (init) await page.addInitScript(init);
  if (throttle > 1) {
    const cdp = await ctx.newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
  }
  return { ctx, page };
}
const settle = async (page, js = true) => {
  await page.waitForLoadState("load").catch(() => {});
  await page.waitForTimeout(js ? 1200 : 300);
};
const textLength = (page) => page.evaluate(() => (document.querySelector("main") ?? document.body).innerText.replace(/\s+/g, "").length);

try {
  // Errors and title, desktop, JavaScript on.
  const errors = [];
  {
    const { ctx, page } = await open({ width: 1440 });
    page.on("console", (m) => m.type() === "error" && errors.push(`console: ${m.text().slice(0, 160)}`));
    page.on("pageerror", (e) => errors.push(`pageerror: ${String(e.message).slice(0, 160)}`));
    page.on("requestfailed", (r) => {
      const f = r.failure()?.errorText ?? "";
      if (!/ERR_ABORTED/.test(f)) errors.push(`request: ${r.url().slice(0, 120)} ${f}`);
    });
    const res = await page.goto(args.url, { waitUntil: "load", timeout: 45000 });
    await settle(page);
    const title = await page.title();
    add("served", res && res.ok(), `HTTP ${res?.status()} — title "${title}"`);
    // Scroll through so lazy content loads and late errors surface.
    await page.evaluate(async () => {
      for (let y = 0; y < document.documentElement.scrollHeight; y += innerHeight * 0.8) {
        scrollTo(0, y);
        await new Promise((r) => setTimeout(r, 120));
      }
      scrollTo(0, 0);
    });
    await page.waitForTimeout(500);
    add("errors", errors.length === 0, errors.slice(0, 10));

    const dom = await page.evaluate(() => {
      const visible = (el) => {
        const s = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        return s.visibility !== "hidden" && s.display !== "none" && r.width > 0 && r.height > 0;
      };
      const inNeeds = (el) => !!el.closest("[data-needs-input]");
      const badLinks = [];
      for (const a of document.querySelectorAll("a[href]")) {
        const h = a.getAttribute("href").trim();
        if (inNeeds(a)) continue;
        if (h === "" || h === "#" || /^javascript:/i.test(h)) badLinks.push(`${h || "(empty)"} — "${a.textContent.trim().slice(0, 40)}"`);
        else if (h.startsWith("#") && !document.getElementById(decodeURIComponent(h.slice(1)))) badLinks.push(`${h} — no such id`);
      }
      const ph = /\[[^\]\n]{0,40}(필요|입력|TBD|TODO|placeholder|lorem)[^\]\n]{0,40}\]/i;
      const placeholders = [];
      const needs = [];
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const n = walker.currentNode;
        const m = n.textContent.match(ph);
        if (!m || !n.parentElement || !visible(n.parentElement)) continue;
        (inNeeds(n.parentElement) ? needs : placeholders).push(m[0]);
      }
      for (const el of document.querySelectorAll("[data-needs-input]")) needs.push((el.getAttribute("data-needs-input") || el.textContent).trim().slice(0, 60));
      return { badLinks, placeholders, needs, moments: document.querySelectorAll("[data-moment]").length };
    });
    add("destinations", dom.badLinks.length === 0, dom.badLinks);
    add("placeholders", dom.placeholders.length === 0, dom.placeholders);
    needsInput.push(...new Set(dom.needs));
    if (level !== "calm") add("moments_marked", dom.moments > 0, `${dom.moments} element(s) with data-moment at motion level ${level}`);
    const jsOn = await textLength(page);
    await ctx.close();

    // Content kept with JavaScript off and under reduced motion.
    const off = await open({ width: 1440, js: false });
    await off.page.goto(args.url, { waitUntil: "load" });
    await settle(off.page, false);
    const jsOff = await textLength(off.page);
    await off.ctx.close();
    add("js_off_content", jsOff >= jsOn * cfg.js_off_text_ratio, `${jsOff}/${jsOn} characters`);
    const rm = await open({ width: 1440, reduced: true });
    await rm.page.goto(args.url, { waitUntil: "load" });
    await settle(rm.page);
    const rmLen = await textLength(rm.page);
    // Contrast on the settled (reduced-motion) page: what is actually under each text, not the ancestor chain —
    // a photo laid as a sibling <img> is media, so that text goes to the reviewer instead of being scored against white.
    const contrast = await rm.page.evaluate(() => {
      const lum = (c) => {
        const m = c.match(/rgba?\(([^)]+)\)/);
        if (!m) return null;
        const [r, g, b, a = 1] = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
        const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
        return { L: 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b), a };
      };
      const low = [];
      const overMedia = [];
      let unknown = 0;
      for (const el of document.querySelectorAll("body *")) {
        if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
        const s = getComputedStyle(el);
        if (s.visibility === "hidden" || s.display === "none" || Number(s.opacity) === 0 || el.closest("[aria-hidden=true]")) continue;
        let r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) continue;
        if (s.position === "absolute" && r.width <= 1) continue;
        el.scrollIntoView({ block: "center", behavior: "instant" });
        r = el.getBoundingClientRect();
        // Off-screen until focused (a skip link) or clipped away: not something a visitor reads in this state.
        if (r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) continue;
        const fg = lum(s.color);
        if (!fg) { unknown++; continue; }
        const stack = document.elementsFromPoint(r.left + Math.min(r.width / 2, 8), r.top + r.height / 2);
        let bg = null;
        let media = false;
        for (const n of stack) {
          if (n !== el && el.contains(n)) continue;
          const ns = getComputedStyle(n);
          if (/^(IMG|VIDEO|CANVAS|PICTURE|IFRAME)$/.test(n.tagName) || ns.backgroundImage !== "none") { media = true; break; }
          const b = lum(ns.backgroundColor);
          if (b && b.a >= 0.99) { bg = b; break; }
        }
        const label = `${el.tagName.toLowerCase()} "${el.textContent.trim().slice(0, 30)}"`;
        if (media) { overMedia.push(label); continue; }
        bg ??= lum(getComputedStyle(document.body).backgroundColor) ?? { L: 1 };
        const ratio = (Math.max(fg.L, bg.L) + 0.05) / (Math.min(fg.L, bg.L) + 0.05);
        const size = parseFloat(s.fontSize);
        const large = size >= 24 || (size >= 18.66 && Number(s.fontWeight) >= 700);
        if (ratio < (large ? 3 : 4.5)) low.push(`${label} ${ratio.toFixed(2)}:1`);
      }
      return { low, overMedia: overMedia.slice(0, 20), unknown };
    });
    add("contrast_solid", contrast.low.length === 0, contrast.low.slice(0, 15));
    add("contrast_over_media", null, { for_reviewer: contrast.overMedia, unparsed_colors: contrast.unknown });
    await rm.ctx.close();
    add("reduced_motion_content", rmLen >= jsOn * cfg.reduced_motion_text_ratio, `${rmLen}/${jsOn} characters`);
  }

  // Overflow per width (JavaScript on, and off at phone widths) and the main action in the first viewport.
  const overflow = [];
  const action = [];
  for (const width of cfg.widths) {
    for (const js of width <= 390 ? [true, false] : [true]) {
      const { ctx, page } = await open({ width, height: width <= 390 ? 844 : 900, js });
      await page.goto(args.url, { waitUntil: "load" });
      await settle(page, js);
      const r = await page.evaluate(() => {
        const se = document.scrollingElement;
        const a = document.querySelector("[data-primary-action]");
        const rect = a?.getBoundingClientRect();
        return { sw: se.scrollWidth, cw: se.clientWidth, marked: !!a, inView: !!rect && rect.top >= 0 && rect.bottom <= innerHeight && rect.width > 0 };
      });
      if (r.sw > r.cw + 1) overflow.push(`${width}${js ? "" : " (JS off)"}: ${r.sw}px > ${r.cw}px`);
      if (js && (width === 1440 || width === 390)) action.push({ width, ...r });
      await ctx.close();
    }
  }
  add("overflow", overflow.length === 0, overflow);
  const unmarked = action.some((a) => !a.marked);
  add("first_action", unmarked ? false : action.every((a) => a.inView), unmarked ? "mark the main action with data-primary-action" : action.map((a) => `${a.width}: ${a.inView ? "in first viewport" : "below the first viewport"}`));

  // First-run frame rate of each moving moment, operated the way a visitor does.
  const recorder = `window.__frames=[];(function f(t){__frames.push(t);requestAnimationFrame(f)})(performance.now());`;
  const momentResults = [];
  const probe = await open({ width: 1440 });
  await probe.page.goto(args.url, { waitUntil: "load" });
  const marked = await probe.page.evaluate(() => [...document.querySelectorAll("[data-moment]")].map((el, i) => ({ i, kind: el.dataset.moment, label: el.getAttribute("aria-label") || el.id || el.className.toString().slice(0, 40) })));
  await probe.ctx.close();
  for (const m of marked) {
    for (const [profile, p] of Object.entries(cfg.moments)) {
      const { ctx, page } = await open({ width: p.width, height: p.width <= 390 ? 844 : 900, throttle: p.cpu_throttle, init: recorder });
      try {
        await page.goto(args.url, { waitUntil: "load" });
        await page.waitForTimeout(600);
        const el = page.locator("[data-moment]").nth(m.i);
        await el.evaluate((n) => n.scrollIntoView({ block: n.dataset.moment === "scroll" ? "start" : "center" }));
        if (m.kind === "scroll") await page.mouse.wheel(0, -400);
        await page.waitForTimeout(300);
        await page.evaluate(() => { window.__frames = []; });
        const box = await el.boundingBox();
        const vh = p.width <= 390 ? 844 : 900;
        if (m.kind === "scroll") {
          const dist = (box?.height ?? vh) + vh;
          for (let y = 0; y < dist; y += 120) { await page.mouse.wheel(0, 120); await page.waitForTimeout(50); }
        } else if (m.kind === "type") {
          const input = el.locator("input, textarea, [contenteditable]").first();
          const target = (await input.count()) ? input : el;
          await target.click({ timeout: 5000 });
          const sample = (await el.getAttribute("data-moment-sample")) || "데이터를 분석해 문제를 찾고 개선한 경험";
          await page.keyboard.type(sample, { delay: 45 });
        } else {
          const b = box ?? { x: 0, y: 0, width: p.width, height: vh };
          const steps = 40;
          for (let k = 0; k <= steps; k++) { await page.mouse.move(b.x + (b.width * k) / steps, b.y + (b.height * (0.3 + 0.4 * Math.sin(k / 5)))); await page.waitForTimeout(30); }
        }
        await page.waitForTimeout(300);
        const stat = await page.evaluate(() => {
          const f = window.__frames;
          const d = f.slice(1).map((t, i) => t - f[i]);
          const avg = d.reduce((a, b) => a + b, 0) / Math.max(d.length, 1);
          return { fps: Math.round(1000 / avg), worst: Math.round(Math.max(0, ...d)), lite: document.documentElement.dataset.motionTier === "lite" };
        });
        const ok = (stat.fps >= p.min_fps && stat.worst <= p.max_frame_ms) || Boolean(p.lite_tier_passes && stat.lite);
        momentResults.push({ moment: m.label, kind: m.kind, profile, width: p.width, cpu_throttle: p.cpu_throttle, ...stat, pass: ok });
      } catch (e) {
        momentResults.push({ moment: m.label, kind: m.kind, profile, error: String(e.message).split("\n")[0], pass: null });
      }
      await ctx.close();
    }
  }
  const failedMoments = momentResults.filter((r) => r.pass === false);
  const brokenMoments = momentResults.filter((r) => r.pass === null);
  add("moment_frame_rate", brokenMoments.length ? (failedMoments.length ? false : null) : failedMoments.length === 0, momentResults);

  const failed = checks.filter((c) => c.status === "fail" && c.id !== "contrast_over_media");
  const unknown = checks.filter((c) => c.status === "unverified" && c.id !== "contrast_over_media");
  write({ result: failed.length ? "fail" : unknown.length ? "unverified" : "pass", url: args.url, motion_level: level, checks, moments: momentResults, needs_input: needsInput });
} catch (e) {
  write({ result: "unverified", reason: String(e.message).split("\n")[0], checks, needs_input: needsInput });
} finally {
  await browser.close();
}
