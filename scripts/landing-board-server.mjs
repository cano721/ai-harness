#!/usr/bin/env node
// /landing-page board server: serves WORK read-only and takes the user's pick from the board, so the user can choose on
// the page and start without typing the answer into the terminal.
//   node landing-board-server.mjs --work DIR --port N [--idle-minutes M]
// It exits by itself after M minutes (default 30, LANDING_BOARD_IDLE_MINUTES; 0 keeps it up) without a request. An open
// board page asks /pick every few minutes, so the server lives while someone has the board open and goes away after the
// tab is closed; `board --serve` starts it again.
//   GET  <path>  a file inside WORK (never a dotfile such as .landing-run)
//   GET  /pick   {"server": true, "run": <a landing run is in WORK>} — the board takes picks only with a run; a board that
//                /design-references serves alone is for looking, and its pick bar shows the summary to paste instead
//   GET  /state?node=reference_pick|draft_pick  {node: <the run's current node>, picked: <that pick, once made, or null>}
//   POST /pick   {node: "reference_pick", tone, kept, dropped, add_sites, primary, user_words} → reference-pick.json
//                {node: "draft_pick", kept: [one id], dropped, user_words}           → draft-pick.json
// The pick is checked and written by landing-pick.mjs, the same command the Harness Board runs: once per node, while the
// run is at it (409 already_started otherwise), and the reference board's run record is marked picked.
// Binds 127.0.0.1 only. POST needs Content-Type application/json and, when the browser sends an Origin, this server's
// own origin, so another page open in the browser cannot write a pick.
import { createServer } from "node:http";
import { existsSync, statSync, createReadStream } from "node:fs";
import { extname, normalize, resolve, sep } from "node:path";
import { PICK_FILE, state, writePick } from "./landing-pick.mjs";

const argv = process.argv.slice(2);
const opt = (k) => (argv.indexOf(k) >= 0 ? argv[argv.indexOf(k) + 1] : "");
const work = resolve(opt("--work") || "");
const port = Number(opt("--port"));
const idleMinutes = Number(opt("--idle-minutes") || process.env.LANDING_BOARD_IDLE_MINUTES || "30");
if (!opt("--work") || !Number.isInteger(port) || port < 1 || port > 65535 || !(idleMinutes >= 0)) {
  console.error("usage: landing-board-server.mjs --work DIR --port N [--idle-minutes M]");
  process.exit(2);
}

const TYPES = { ".html": "text/html; charset=utf-8", ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg", ".webp": "image/webp", ".gif": "image/gif", ".svg": "image/svg+xml", ".mp4": "video/mp4",
  ".webm": "video/webm", ".css": "text/css", ".js": "text/javascript" };
const send = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
};
let lastHit = Date.now();
const server = createServer((req, res) => {
  lastHit = Date.now();
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (url.pathname === "/state") {
    if (req.method !== "GET") return send(res, 405, { error: "method not allowed" });
    const node = url.searchParams.get("node");
    if (!PICK_FILE[node]) return send(res, 400, { error: "node must be reference_pick or draft_pick" });
    return send(res, 200, state(work, node));
  }
  if (url.pathname === "/pick") {
    if (req.method === "GET") return send(res, 200, { server: true, run: state(work, "reference_pick").node !== null });
    if (req.method !== "POST") return send(res, 405, { error: "method not allowed" });
    const origin = req.headers.origin;
    if (origin && origin !== `http://127.0.0.1:${port}` && origin !== `http://localhost:${port}`) return send(res, 403, { error: "foreign origin" });
    if (!String(req.headers["content-type"] ?? "").startsWith("application/json")) return send(res, 415, { error: "send application/json" });
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (c) => {
      raw += c;
      if (raw.length > 65536) { send(res, 413, { error: "body too large" }); req.destroy(); }
    });
    req.on("end", () => {
      if (res.writableEnded) return;
      let body;
      try { body = JSON.parse(raw); } catch { return send(res, 400, { error: "body is not JSON" }); }
      const { status, ...out } = writePick(work, body);
      if (status === 200) console.log(`pick written: ${out.file}`);
      return send(res, status, out);
    });
    return;
  }
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: "method not allowed" });
  let decoded;
  try { decoded = decodeURIComponent(url.pathname); } catch { return send(res, 400, { error: "bad path" }); }
  const rel = normalize(decoded).replace(/^[/\\]+/, "") || "board.html";
  const path = resolve(work, rel);
  if (!path.startsWith(work + sep) || rel.split(/[/\\]/).some((p) => p.startsWith(".")) || !existsSync(path) || !statSync(path).isFile()) {
    return send(res, 404, { error: "not found" });
  }
  res.writeHead(200, { "content-type": TYPES[extname(path).toLowerCase()] ?? "application/octet-stream", "cache-control": "no-store" });
  if (req.method === "HEAD") return res.end();
  createReadStream(path).pipe(res);
});
if (idleMinutes > 0) {
  const idleMs = idleMinutes * 60000;
  setInterval(() => {
    if (Date.now() - lastHit < idleMs) return;
    console.log(`idle ${idleMinutes} min: exiting`);
    process.exit(0);
  }, Math.min(idleMs, 30000));
}
server.listen(port, "127.0.0.1", () => console.log(`board server: http://127.0.0.1:${port}/`));
