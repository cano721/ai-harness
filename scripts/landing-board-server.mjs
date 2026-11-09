#!/usr/bin/env node
// /landing-page board server: serves WORK read-only and takes the user's pick from the board, so the user can choose on
// the page and start without typing the answer into the terminal.
//   node landing-board-server.mjs --work DIR --port N
//   GET  <path>  a file inside WORK (never a dotfile such as .landing-run)
//   GET  /pick   {"server": true} — the board uses it to tell a live server from a static one
//   POST /pick   {node: "reference_pick", tone, kept, dropped, add_sites, user_words} → reference-pick.json
//                {node: "draft_pick", kept: [one id], dropped, user_words}           → draft-pick.json
// Binds 127.0.0.1 only. POST needs Content-Type application/json and, when the browser sends an Origin, this server's
// own origin, so another page open in the browser cannot write a pick.
import { createServer } from "node:http";
import { existsSync, readFileSync, renameSync, statSync, writeFileSync, createReadStream } from "node:fs";
import { extname, join, normalize, resolve, sep } from "node:path";

const argv = process.argv.slice(2);
const opt = (k) => (argv.indexOf(k) >= 0 ? argv[argv.indexOf(k) + 1] : "");
const work = resolve(opt("--work") || "");
const port = Number(opt("--port"));
if (!opt("--work") || !Number.isInteger(port) || port < 1 || port > 65535) {
  console.error("usage: landing-board-server.mjs --work DIR --port N");
  process.exit(2);
}

const TYPES = { ".html": "text/html; charset=utf-8", ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg", ".webp": "image/webp", ".gif": "image/gif", ".svg": "image/svg+xml", ".mp4": "video/mp4",
  ".webm": "video/webm", ".css": "text/css", ".js": "text/javascript" };
const send = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
};
const readJson = (f) => {
  try { return JSON.parse(readFileSync(join(work, f), "utf8")); } catch { return null; }
};
const isStr = (v) => typeof v === "string";
const ids = (v) => Array.isArray(v) && v.every((x) => isStr(x) && x.length > 0 && x.length <= 200);

function pick(body) {
  if (!body || typeof body !== "object") return ["body must be a JSON object"];
  const words = body.user_words ?? "";
  if (!isStr(words) || words.length > 5000) return ["user_words must be text"];
  if (!ids(body.kept ?? []) || !ids(body.dropped ?? [])) return ["kept and dropped must be lists of ids"];
  const kept = body.kept ?? [], dropped = body.dropped ?? [];
  if (body.node === "reference_pick") {
    const known = new Set((readJson("references.json") ?? []).map((r) => r.id));
    const unknown = [...kept, ...dropped].filter((i) => !known.has(i));
    if (unknown.length) return [`unknown reference ids: ${unknown.join(", ")}`];
    if (!kept.length) return ["keep at least one reference"];
    if (!isStr(body.tone) || !body.tone.trim() || body.tone.length > 2000) return ["tone must be text: kept, or the change"];
    const sites = body.add_sites ?? [];
    if (!Array.isArray(sites) || !sites.every((u) => isStr(u) && /^https?:\/\/\S+$/i.test(u) && u.length <= 500)) return ["add_sites must be http(s) URLs"];
    return [null, "reference-pick.json", { tone: body.tone.trim(), kept, dropped, add_sites: sites, user_words: words, via: "board" }];
  }
  if (body.node === "draft_pick") {
    const known = new Set((readJson("candidates.json")?.candidates ?? []).map((c) => c.id));
    const unknown = [...kept, ...dropped].filter((i) => !known.has(i));
    if (unknown.length) return [`unknown candidate ids: ${unknown.join(", ")}`];
    if (kept.length !== 1) return ["pick exactly one candidate"];
    return [null, "draft-pick.json", { kept, dropped, user_words: words, via: "board" }];
  }
  return ["node must be reference_pick or draft_pick"];
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (url.pathname === "/pick") {
    if (req.method === "GET") return send(res, 200, { server: true });
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
      const [err, file, data] = pick(body);
      if (err) return send(res, 400, { error: err });
      const tmp = join(work, `.${file}.${process.pid}.tmp`);
      writeFileSync(tmp, JSON.stringify({ ...data, at: new Date().toISOString() }, null, 2) + "\n");
      renameSync(tmp, join(work, file));
      console.log(`pick written: ${file}`);
      return send(res, 200, { ok: true, file });
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
server.listen(port, "127.0.0.1", () => console.log(`board server: http://127.0.0.1:${port}/`));
