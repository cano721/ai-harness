// Shared by the landing-page measure and capture scripts: start the requested engine (default Chromium) from the first Playwright install that works.
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

const ENGINES = { chromium: "Chromium", webkit: "WebKit", firefox: "Firefox" };

// Returns {browser, engine} or {reason, tried}. Starts only the requested engine; it never falls back to another one,
// because a screen checked in a different engine than the one users see is not verified.
export async function launchBrowser({ engine = "chromium" } = {}) {
  const tried = [];
  if (!Object.hasOwn(ENGINES, engine)) {
    return { reason: `Unknown render engine "${engine}" (use chromium, webkit, or firefox)`, tried };
  }
  const name = ENGINES[engine];
  const req = createRequire(import.meta.url);
  for (const t of playwrightCandidates()) {
    let pw;
    try {
      pw = req(t);
    } catch {
      continue;
    }
    try {
      return { browser: await pw[engine].launch(), engine };
    } catch (e) {
      tried.push(`${t}: ${String(e.message).split("\n")[0].slice(0, 160)}`);
    }
  }
  return {
    reason: tried.length
      ? `No Playwright install could start ${name} (install it with the user's approval: npx playwright install ${engine})`
      : `Playwright not found (set LANDING_PLAYWRIGHT to its module path, or install it with the user's approval: npx playwright install ${engine})`,
    tried,
  };
}
