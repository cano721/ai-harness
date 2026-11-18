#!/usr/bin/env node
// /landing-page preview server: serves one page folder read-only so measure, capture and the person open it over http
// (module scripts and some fonts fail under file://). Started by `landing-run.sh serve`, never by hand.
//   node landing-serve.mjs --root DIR [--port N] [--idle-minutes M]
// --port 0 (the default) takes a free port. Prints "serving: http://127.0.0.1:<port>/" once listening.
// It exits by itself after M minutes (default 30, LANDING_SERVE_IDLE_MINUTES) without a request: an agent that served a
// draft and moved on, or a run that ended, does not leave a server behind for days. Asking `serve` again starts a new one.
// Binds 127.0.0.1 only; never serves dotfiles or anything outside DIR.
import { createServer } from "node:http";
import { existsSync, statSync, createReadStream } from "node:fs";
import { extname, join, normalize, resolve, sep } from "node:path";

const argv = process.argv.slice(2);
const opt = (k, d = "") => (argv.indexOf(k) >= 0 ? argv[argv.indexOf(k) + 1] : d);
const root = resolve(opt("--root") || "");
const port = Number(opt("--port", "0"));
const idleMinutes = Number(opt("--idle-minutes", process.env.LANDING_SERVE_IDLE_MINUTES || "30"));
if (!opt("--root") || !existsSync(root) || !statSync(root).isDirectory() || !Number.isInteger(port) || port < 0 || port > 65535
  || !(idleMinutes >= 0)) {
  console.error("usage: landing-serve.mjs --root DIR [--port N] [--idle-minutes M]");
  process.exit(2);
}

const TYPES = { ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".css": "text/css",
  ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json", ".map": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
  ".avif": "image/avif", ".gif": "image/gif", ".ico": "image/x-icon", ".woff": "font/woff", ".woff2": "font/woff2",
  ".ttf": "font/ttf", ".otf": "font/otf", ".mp4": "video/mp4", ".webm": "video/webm", ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml", ".webmanifest": "application/manifest+json" };

let lastHit = Date.now();
const notFound = (res) => { res.writeHead(404, { "content-type": "text/plain" }); res.end("not found"); };
const server = createServer((req, res) => {
  lastHit = Date.now();
  if (req.method !== "GET" && req.method !== "HEAD") { res.writeHead(405); return res.end(); }
  let rel;
  try { rel = normalize(decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname)).replace(/^[/\\]+/, ""); }
  catch { res.writeHead(400); return res.end(); }
  if (rel.split(/[/\\]/).some((p) => p.startsWith("."))) return notFound(res);
  let path = resolve(root, rel);
  if (path !== root && !path.startsWith(root + sep)) return notFound(res);
  if (existsSync(path) && statSync(path).isDirectory()) path = join(path, "index.html");
  if (!existsSync(path) || !statSync(path).isFile()) return notFound(res);
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
server.listen(port, "127.0.0.1", () => console.log(`serving: http://127.0.0.1:${server.address().port}/`));
