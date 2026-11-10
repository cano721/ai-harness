#!/usr/bin/env node
// /landing-page board server: serves WORK read-only and takes the user's pick from the board, so the user can choose on
// the page and start without typing the answer into the terminal.
//   node landing-board-server.mjs --work DIR --port N
//   GET  <path>  a file inside WORK (never a dotfile such as .landing-run)
//   GET  /pick   {"server": true} — the board uses it to tell a live server from a static one
//   GET  /state?node=reference_pick|draft_pick  {node: <the run's current node>, picked: <that pick, once made, or null>}
//   POST /pick   {node: "reference_pick", tone, kept, dropped, add_sites, primary, user_words} → reference-pick.json
//                {node: "draft_pick", kept: [one id], dropped, user_words}           → draft-pick.json
// A pick is written only while the run is at that node and has no pick from this node yet (409 already_started
// otherwise): the session submits the pick as soon as it appears, so a second press must not rewrite what was submitted.
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

// The primary references: one layout, one interaction, one component (or none) per section slot, none excluded.
// The runner checks the same shape when the pick is submitted; this keeps a bad pick from being written at all.
const SLOT_ID = /^[a-z0-9][a-z0-9_-]*$/;
function checkPrimary(p, refs, dropped) {
  if (!p || typeof p !== "object" || Array.isArray(p)) return ["primary must be {layout, interaction, components, added_slots}"];
  const ok = (id, kind) => isStr(id) && refs.some((r) => r.id === id && r.kind === kind) && !dropped.includes(id);
  if (!ok(p.layout, "layout")) return ["primary.layout must be a layout reference that is not excluded"];
  if (!ok(p.interaction, "interaction")) return ["primary.interaction must be an interaction reference that is not excluded"];
  const added = p.added_slots ?? [];
  if (!Array.isArray(added) || added.length > 20 || !added.every((a) => a && SLOT_ID.test(a.id ?? "") && isStr(a.label) && a.label.trim() && a.label.length <= 80))
    return ["primary.added_slots must be [{id, label}]"];
  const base = (readJson("component-slots.json") ?? []).map((s) => s.id);
  if (added.some((a) => base.includes(a.id))) return ["an added slot reuses an existing slot id"];
  const slots = [...base, ...added.map((a) => a.id)];
  const comps = p.components ?? {};
  if (typeof comps !== "object" || Array.isArray(comps)) return ["primary.components must map slot ids to a component id or null"];
  for (const [k, v] of Object.entries(comps)) {
    if (!slots.includes(k)) return [`primary.components: ${k} is not a slot`];
    if (v !== null && !ok(v, "component")) return [`primary.components.${k} must be a component reference that is not excluded`];
  }
  return [null, { layout: p.layout, interaction: p.interaction, components: comps, added_slots: added.map((a) => ({ id: a.id, label: a.label.trim() })) }];
}

function pick(body) {
  if (!body || typeof body !== "object") return ["body must be a JSON object"];
  const words = body.user_words ?? "";
  if (!isStr(words) || words.length > 5000) return ["user_words must be text"];
  if (!ids(body.kept ?? []) || !ids(body.dropped ?? [])) return ["kept and dropped must be lists of ids"];
  const kept = body.kept ?? [], dropped = body.dropped ?? [];
  if (body.node === "reference_pick") {
    const refs = readJson("references.json") ?? [];
    const known = new Set(refs.map((r) => r.id));
    const unknown = [...kept, ...dropped].filter((i) => !known.has(i));
    if (unknown.length) return [`unknown reference ids: ${unknown.join(", ")}`];
    if (!kept.length) return ["keep at least one reference"];
    if (!isStr(body.tone) || !body.tone.trim() || body.tone.length > 2000) return ["tone must be text: kept, or the change"];
    const sites = body.add_sites ?? [];
    if (!Array.isArray(sites) || !sites.every((u) => isStr(u) && /^https?:\/\/\S+$/i.test(u) && u.length <= 500)) return ["add_sites must be http(s) URLs"];
    const [perr, primary] = checkPrimary(body.primary, refs, dropped);
    if (perr) return [perr];
    return [null, "reference-pick.json", { tone: body.tone.trim(), kept, dropped, add_sites: sites, primary, user_words: words, via: "board" }];
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

const PICK_FILE = { reference_pick: "reference-pick.json", draft_pick: "draft-pick.json" };
// The run's current node and when it started (epoch ms), or null without a run.
function runNode() {
  const st = readJson(".landing-run/state.json");
  if (!st) return null;
  return { node: st.node, since: Date.parse(st.entered_at ?? "") || 0 };
}
// The pick for NODE: made in this node (at it, written after it started), or kept from it once the run has moved on.
function pickedFor(node, run) {
  const f = join(work, PICK_FILE[node]);
  if (!existsSync(f)) return null;
  if (run?.node === node && Math.floor(statSync(f).mtimeMs / 1000) * 1000 < run.since) return null;
  return readJson(PICK_FILE[node]);
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (url.pathname === "/state") {
    if (req.method !== "GET") return send(res, 405, { error: "method not allowed" });
    const node = url.searchParams.get("node");
    if (!PICK_FILE[node]) return send(res, 400, { error: "node must be reference_pick or draft_pick" });
    const run = runNode();
    return send(res, 200, { node: run?.node ?? null, picked: pickedFor(node, run) });
  }
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
      const run = runNode();
      if (run?.node !== body.node || pickedFor(body.node, run)) return send(res, 409, { error: "already_started", node: run?.node ?? null });
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
