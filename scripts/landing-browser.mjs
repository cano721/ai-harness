// Shared by the landing-page measure and capture scripts: start Chromium from the first Playwright install that works.
import { createRequire } from "node:module";
import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

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

// Returns {browser} or {reason, tried} when no install could start Chromium.
export async function launchBrowser() {
  const req = createRequire(import.meta.url);
  const tried = [];
  for (const t of playwrightCandidates()) {
    let pw;
    try {
      pw = req(t);
    } catch {
      continue;
    }
    try {
      return { browser: await pw.chromium.launch() };
    } catch (e) {
      tried.push(`${t}: ${String(e.message).split("\n")[0].slice(0, 160)}`);
    }
  }
  return {
    reason: tried.length
      ? "No Playwright install could start Chromium"
      : "Playwright not found (set LANDING_PLAYWRIGHT to its module path, or install it with the user's approval)",
    tried,
  };
}
