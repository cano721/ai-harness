#!/usr/bin/env node
// Drives the served reference board as a user would: move the layout star, add a section slot, give it a component,
// press start. Prints {result, layout, slot}; the test then reads reference-pick.json. Shots land in --shots.
//   node primary-e2e.mjs --url http://127.0.0.1:<port>/board.html --shots DIR
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser } from "../../../scripts/landing-browser.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("--") ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
if (!args.url || !args.shots) {
  console.error("usage: primary-e2e.mjs --url BOARD_URL --shots DIR");
  process.exit(2);
}
mkdirSync(args.shots, { recursive: true });
const { browser, reason } = await launchBrowser();
if (!browser) {
  console.log(JSON.stringify({ result: "unverified", reason }));
  process.exit(0);
}
const shot = (page, name) => page.screenshot({ path: join(args.shots, `primary-${name}.png`) });
try {
  const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(args.url, { waitUntil: "load" });
  await page.click('nav button[data-tab="layout"]');
  await page.waitForTimeout(300);
  await shot(page, "1-layout-recommended");
  const other = page.locator('.star[data-group="layout"][aria-pressed="false"]').first();
  const layout = await other.getAttribute("data-id");
  await other.click();
  await shot(page, "2-layout-moved");
  await page.click('nav button[data-tab="component"]');
  await page.fill("#new-slot", "연동");
  await page.click("#add-slot");
  // A component that was not recommended for any slot, so the recommended ones stay where they were.
  const sel = page.locator(".slot-pick select").nth(2);
  await sel.selectOption("extra-1");
  await page.waitForTimeout(200);
  await shot(page, "3-components-slot-added");
  await page.click(".start");
  await page.waitForSelector("text=받았어요", { timeout: 5000 });
  await shot(page, "4-started");
  console.log(JSON.stringify({ result: errors.length ? "error" : "done", layout, slot: "extra-1", component: await sel.getAttribute("data-id"), errors }));
} catch (e) {
  console.log(JSON.stringify({ result: "error", error: String(e.message).split("\n")[0] }));
} finally {
  await browser.close();
}
