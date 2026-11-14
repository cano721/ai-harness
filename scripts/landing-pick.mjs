#!/usr/bin/env node
// The pick a landing run waits for at reference_pick and draft_pick: checked, written once, and the reference board's run
// record marked picked. The landing board server (landing-board-server.mjs) imports it and the Harness Board calls it as a
// command, so both write the same file the same way.
//   node landing-pick.mjs state --work DIR --node reference_pick|draft_pick   → {node, picked}
//   node landing-pick.mjs write --work DIR [--run-id ID] < pick.json          → {status, ok, file} or {status, error, node?}
// A pick is written only while the run is at that node and has no pick from this node yet (409 already_started
// otherwise): the session submits the pick as soon as it appears, so a second press must not rewrite what was submitted.
// `write` prints its HTTP-like status in the JSON and exits 0; exit 2 is a usage error.
import { existsSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

export const PICK_FILE = { reference_pick: "reference-pick.json", draft_pick: "draft-pick.json" };

const readJson = (work, f) => {
  try { return JSON.parse(readFileSync(join(work, f), "utf8")); } catch { return null; }
};
const isStr = (v) => typeof v === "string";
const ids = (v) => Array.isArray(v) && v.every((x) => isStr(x) && x.length > 0 && x.length <= 200);

// The primary references: one layout, one interaction, one component (or none) per section slot, none excluded.
// The runner checks the same shape when the pick is submitted; this keeps a bad pick from being written at all.
const SLOT_ID = /^[a-z0-9][a-z0-9_-]*$/;
function checkPrimary(work, p, refs, dropped) {
  if (!p || typeof p !== "object" || Array.isArray(p)) return ["primary must be {layout, interaction, components, added_slots}"];
  const ok = (id, kind) => isStr(id) && refs.some((r) => r.id === id && r.kind === kind) && !dropped.includes(id);
  if (!ok(p.layout, "layout")) return ["primary.layout must be a layout reference that is not excluded"];
  if (!ok(p.interaction, "interaction")) return ["primary.interaction must be an interaction reference that is not excluded"];
  const added = p.added_slots ?? [];
  if (!Array.isArray(added) || added.length > 20 || !added.every((a) => a && SLOT_ID.test(a.id ?? "") && isStr(a.label) && a.label.trim() && a.label.length <= 80))
    return ["primary.added_slots must be [{id, label}]"];
  const base = (readJson(work, "component-slots.json") ?? []).map((s) => s.id);
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

// [error] or [null, file, record] for a pick body.
export function checkPick(work, body) {
  if (!body || typeof body !== "object") return ["body must be a JSON object"];
  const words = body.user_words ?? "";
  if (!isStr(words) || words.length > 5000) return ["user_words must be text"];
  if (!ids(body.kept ?? []) || !ids(body.dropped ?? [])) return ["kept and dropped must be lists of ids"];
  const kept = body.kept ?? [], dropped = body.dropped ?? [];
  if (body.node === "reference_pick") {
    const refs = readJson(work, "references.json") ?? [];
    const known = new Set(refs.map((r) => r.id));
    const unknown = [...kept, ...dropped].filter((i) => !known.has(i));
    if (unknown.length) return [`unknown reference ids: ${unknown.join(", ")}`];
    if (!kept.length) return ["keep at least one reference"];
    if (!isStr(body.tone) || !body.tone.trim() || body.tone.length > 2000) return ["tone must be text: kept, or the change"];
    const sites = body.add_sites ?? [];
    if (!Array.isArray(sites) || !sites.every((u) => isStr(u) && /^https?:\/\/\S+$/i.test(u) && u.length <= 500)) return ["add_sites must be http(s) URLs"];
    const [perr, primary] = checkPrimary(work, body.primary, refs, dropped);
    if (perr) return [perr];
    return [null, PICK_FILE.reference_pick, { tone: body.tone.trim(), kept, dropped, add_sites: sites, primary, user_words: words, via: "board" }];
  }
  if (body.node === "draft_pick") {
    const known = new Set((readJson(work, "candidates.json")?.candidates ?? []).map((c) => c.id));
    const unknown = [...kept, ...dropped].filter((i) => !known.has(i));
    if (unknown.length) return [`unknown candidate ids: ${unknown.join(", ")}`];
    if (kept.length !== 1) return ["pick exactly one candidate"];
    return [null, PICK_FILE.draft_pick, { kept, dropped, user_words: words, via: "board" }];
  }
  return ["node must be reference_pick or draft_pick"];
}

// The run's current node and when it started (epoch ms), or null without a run.
export function runNode(work) {
  const st = readJson(work, ".landing-run/state.json");
  if (!st) return null;
  return { node: st.node, since: Date.parse(st.entered_at ?? "") || 0 };
}

// The pick for NODE: made in this node (at it, written after it started), or kept from it once the run has moved on.
export function pickedFor(work, node, run) {
  const f = join(work, PICK_FILE[node]);
  if (!existsSync(f)) return null;
  if (run?.node === node && Math.floor(statSync(f).mtimeMs / 1000) * 1000 < run.since) return null;
  return readJson(work, PICK_FILE[node]);
}

export function state(work, node) {
  const run = runNode(work);
  return { node: run?.node ?? null, picked: pickedFor(work, node, run) };
}

// The reference board's run record (design-refs.sh board writes it; the id is the work folder's hash): picked once the
// user starts from a board, so a dashboard listing reference boards can tell which still wait for a pick.
export const runIdOf = (work) => createHash("sha256").update(work).digest("hex").slice(0, 12);
function markPicked(runId) {
  if (!/^[0-9a-f]{12}$/.test(runId)) return;
  const f = join(process.env.HARNESS_METRICS_DIR || join(homedir(), ".ai-harness"), "board", "references", `${runId}.json`);
  try {
    const rec = JSON.parse(readFileSync(f, "utf8"));
    const tmp = `${f}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ ...rec, status: "picked", updated_at: new Date().toISOString() }, null, 2) + "\n");
    renameSync(tmp, f);
  } catch {
    // No record (a board drawn before records existed): nothing to mark.
  }
}

// Check, write once, mark the record: {status: 200, ok, file} | {status: 400|409, error, node?}.
export function writePick(work, body, runId = runIdOf(work)) {
  const [err, file, data] = checkPick(work, body);
  if (err) return { status: 400, error: err };
  const run = runNode(work);
  if (run?.node !== body.node || pickedFor(work, body.node, run)) return { status: 409, error: "already_started", node: run?.node ?? null };
  const tmp = join(work, `.${file}.${process.pid}.tmp`);
  writeFileSync(tmp, JSON.stringify({ ...data, at: new Date().toISOString() }, null, 2) + "\n");
  renameSync(tmp, join(work, file));
  if (body.node === "reference_pick") markPicked(runId);
  return { status: 200, ok: true, file };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const opt = (k) => (argv.indexOf(k) >= 0 ? argv[argv.indexOf(k) + 1] : "");
  const cmd = argv[0], work = opt("--work") ? resolve(opt("--work")) : "";
  const usage = () => {
    console.error("usage: landing-pick.mjs state --work DIR --node reference_pick|draft_pick\n       landing-pick.mjs write --work DIR [--run-id ID] < pick.json");
    process.exit(2);
  };
  if (!work || !existsSync(work)) usage();
  if (cmd === "state") {
    if (!PICK_FILE[opt("--node")]) usage();
    console.log(JSON.stringify(state(work, opt("--node"))));
  } else if (cmd === "write") {
    let body;
    try { body = JSON.parse(readFileSync(0, "utf8")); } catch { console.log(JSON.stringify({ status: 400, error: "body is not JSON" })); process.exit(0); }
    console.log(JSON.stringify(writePick(work, body, opt("--run-id") || runIdOf(work))));
  } else usage();
}
