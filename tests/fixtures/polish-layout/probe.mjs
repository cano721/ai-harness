// 레이아웃 probe를 고정 페이지에 실제 브라우저로 평가한다: node probe.mjs <probe.js> <fixture-dir>
// 출력: {"<page>@<width>": "<kind,kind>" ...} 또는 브라우저를 못 띄우면 {"skip": "<이유>"}
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { launchBrowser } from "../../../scripts/landing-browser.mjs";

const [probePath, dir] = process.argv.slice(2);
const probe = readFileSync(probePath, "utf8");
const { browser, reason } = await launchBrowser();
if (!browser) {
  console.log(JSON.stringify({ skip: reason }));
  process.exit(0);
}
const out = {};
try {
  for (const page of ["band", "ok-app", "overflow", "clipped", "column", "landing"]) {
    for (const width of [360, 1280]) {
      const ctx = await browser.newContext({ viewport: { width, height: 900 } });
      const p = await ctx.newPage();
      await p.goto(pathToFileURL(`${dir}/${page}.html`).href);
      const r = await p.evaluate(probe);
      out[`${page}@${width}`] = r.probe === "layout-probe/1" ? [...new Set(r.issues.map((i) => i.kind))].sort().join(",") : "bad-probe";
      if (process.env.PROBE_DEBUG) console.error(page, width, JSON.stringify(r.issues));
      await ctx.close();
    }
  }
} finally {
  await browser.close();
}
console.log(JSON.stringify(out));
