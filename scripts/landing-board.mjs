#!/usr/bin/env node
// /landing-page board: render the reference board from the run's tone.json and references.json, so every board has the
// same five tabs (tone and manner, components, layout, interaction, competitors) and no agent writes the board's HTML.
//   node landing-board.mjs --work DIR   → DIR/board.html
// Captures and recordings are linked relative to DIR, so serve DIR over http and open /board.html (file:// loses images).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative, isAbsolute } from "node:path";

const argv = process.argv.slice(2);
const at = argv.indexOf("--work");
const work = at >= 0 ? argv[at + 1] : "";
if (!work) {
  console.error("usage: landing-board.mjs --work DIR");
  process.exit(2);
}
const read = (f) => JSON.parse(readFileSync(join(work, f), "utf8"));
const tone = existsSync(join(work, "tone.json")) ? read("tone.json") : {};
const refs = read("references.json");
if (!Array.isArray(refs)) {
  console.error("references.json must be an array");
  process.exit(4);
}

const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const remote = (s) => /^https?:\/\//i.test(s);
// A path inside WORK becomes relative to the board; anything else outside it cannot be served and is shown as missing.
const media = (src) => {
  const s = String(src ?? "");
  if (remote(s)) return s;
  const rel = isAbsolute(s) ? relative(work, s) : s.replace(/^\.\//, "");
  return rel.startsWith("..") ? "" : rel.split("/").map(encodeURIComponent).join("/");
};
const hex = (v) => (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(String(v ?? "")) ? v : "transparent");

const TABS = [
  ["tone", "톤앤매너"],
  ["component", "구성요소"],
  ["layout", "레이아웃"],
  ["interaction", "인터랙션"],
  ["competitor", "경쟁사 분석"],
];

function shots(r) {
  const caps = (r.captures ?? []).map(media).filter(Boolean).map((c) => `<img src="${esc(c)}" alt="${esc(r.title)} 캡처" loading="lazy">`);
  const v = r.video ? media(r.video) : "";
  const video = v ? `<video src="${esc(v)}" muted loop autoplay playsinline></video>` : "";
  return caps.length || video ? `<div class="shots">${video}${caps.join("")}</div>` : `<p class="missing">캡처 없음</p>`;
}

function card(r) {
  const a = r.analysis;
  const analysis = a
    ? `<dl class="analysis"><dt>첫 화면에서 내세우는 것</dt><dd>${esc(a.leads_with)}</dd><dt>주장</dt><dd>${esc(a.claim)}</dd><dt>주 버튼</dt><dd>${esc(a.cta)}</dd><dt>우리와 다른 점</dt><dd>${esc(a.gap)}</dd></dl>`
    : "";
  const lines = [
    r.tone_part && `<p class="tag">톤에서 맡는 것 · ${esc(r.tone_part)}</p>`,
    r.take && `<p><b>가져올 것</b> ${esc(r.take)}</p>`,
    r.keep_strength && `<p><b>지킬 강도</b> ${esc(r.keep_strength)}</p>`,
    r.must_not_shrink_to && `<p><b>이렇게 줄이지 않기</b> ${esc(r.must_not_shrink_to)}</p>`,
  ].filter(Boolean);
  const link = remote(r.url) ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.url)}</a>` : `<span class="src">${esc(r.url)}</span>`;
  return `<article id="${esc(r.id)}"><header><span class="id">${esc(r.id)}</span><h3>${esc(r.title)}</h3>
${link}<span class="src">${esc(r.source)}</span></header>
${shots(r)}${analysis}${lines.join("")}</article>`;
}

function toneHead() {
  const chips = (tone.palette ?? [])
    .map((p) => `<li><span class="chip" style="background:${esc(hex(p.hex))}"></span><b>${esc(p.name)}</b><code>${esc(p.hex)}</code><small>${esc(p.role)}</small></li>`)
    .join("");
  const type = tone.type ?? {};
  if (!tone.mood) return `<p class="missing">tone.json이 없어요. brief의 Tone and manner를 tone.json으로도 내 주세요.</p>`;
  return `<section class="tone">
<div class="mood">${(tone.mood ?? []).map((m) => `<span>${esc(m)}</span>`).join("")}</div>
${tone.avoid ? `<p class="avoid"><b>피할 느낌</b> ${esc(tone.avoid)}</p>` : ""}
<div class="grid"><div><h4>색</h4><ul class="palette">${chips}</ul></div>
<div><h4>서체</h4><p class="type-display">${esc(type.display_sample)}</p><p class="type-body">${esc(type.body_sample)}</p><small>${esc(type.display)} · ${esc(type.body)}</small></div>
<div><h4>말투</h4><blockquote>${esc(tone.voice)}</blockquote><h4>이미지</h4><p>${esc(tone.imagery)}</p></div></div></section>`;
}

const of = (k) => refs.filter((r) => r.kind === k);
const panels = TABS.map(([k]) => {
  const cards = of(k).map(card).join("");
  const body = (k === "tone" ? toneHead() : "") + (cards || `<p class="missing">이 탭의 레퍼런스가 없어요.</p>`);
  return `<section class="panel" id="tab-${k}" role="tabpanel" hidden>${body}</section>`;
}).join("");
const nav = TABS.map(([k, label]) => `<button role="tab" data-tab="${k}" aria-controls="tab-${k}">${label}<small>${of(k).length || ""}</small></button>`).join("");

const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>레퍼런스 보드</title><style>
:root{--bg:#f6f6f4;--card:#fff;--ink:#18191b;--sub:#6b6d70;--line:#e3e3e0;--accent:#c24e00}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 -apple-system,"Apple SD Gothic Neo","Pretendard",system-ui,sans-serif}
header.top{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:16px clamp(16px,4vw,40px) 0}
h1{font-size:20px;margin:0 0 4px}.ask{color:var(--sub);margin:0 0 12px;font-size:14px}
nav{display:flex;gap:4px;overflow-x:auto}nav button{font:inherit;border:0;background:none;padding:10px 14px;border-bottom:3px solid transparent;cursor:pointer;color:var(--sub);white-space:nowrap}
nav button small{margin-left:6px}nav button[aria-selected=true]{color:var(--ink);border-color:var(--accent);font-weight:700}
nav button:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
main{padding:20px clamp(16px,4vw,40px) 60px;max-width:1400px}
article{background:var(--card);border-radius:14px;padding:20px;margin:0 0 18px;border:1px solid var(--line)}
article header{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:baseline;margin-bottom:12px}article h3{margin:0;font-size:17px}
.id{font-weight:700;color:var(--accent)}article a{color:#2a62d6;font-size:13px;word-break:break-all}.src{color:var(--sub);font-size:13px}
.shots{display:flex;gap:10px;overflow-x:auto;margin-bottom:12px}.shots img,.shots video{height:300px;max-width:100%;object-fit:contain;border-radius:8px;border:1px solid var(--line);background:#eee;flex:none}
p{margin:6px 0}.tag{display:inline-block;background:#fff3e8;color:#8a3b00;border-radius:999px;padding:2px 10px;font-size:13px}
.missing{color:var(--sub)}.analysis{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;margin:0 0 10px;font-size:14px}.analysis dt{color:var(--sub)}.analysis dd{margin:0}
.tone{background:var(--card);border-radius:14px;padding:24px;border:1px solid var(--line);margin-bottom:18px}
.mood{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px}.mood span{font-size:22px;font-weight:700;padding:4px 14px;border-radius:999px;background:#f1f1ee}
.avoid{color:#a12a2a}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:24px;margin-top:16px}h4{margin:0 0 8px;font-size:13px;color:var(--sub)}
.palette{list-style:none;padding:0;margin:0;display:grid;gap:8px}.palette li{display:grid;grid-template-columns:32px auto 1fr;gap:2px 10px;align-items:center}
.chip{width:32px;height:32px;border-radius:8px;border:1px solid var(--line);grid-row:span 2}.palette code{font-size:12px;color:var(--sub)}.palette small{grid-column:2/4;color:var(--sub)}
.type-display{font-size:28px;font-weight:800;line-height:1.25;margin:0 0 6px}.type-body{margin:0 0 6px}blockquote{margin:0 0 12px;padding:8px 12px;border-left:3px solid var(--accent);background:#fafaf8}
@media (max-width:600px){.shots img,.shots video{height:220px}.analysis{grid-template-columns:1fr}.analysis dd{margin-bottom:6px}}
</style></head><body>
<header class="top"><h1>레퍼런스 보드</h1><p class="ask">톤앤매너는 이대로 갈지, 각 탭에서 남길 것과 뺄 것, 더 보고 싶은 사이트를 알려 주세요. 레퍼런스는 번호로 말하면 돼요.</p>
<nav role="tablist">${nav}</nav></header><main>${panels}</main>
<script>
const keys=${JSON.stringify(TABS.map(([k]) => k))};
const show=(k)=>{if(!keys.includes(k))k=keys[0];document.querySelectorAll('.panel').forEach(p=>p.hidden=p.id!=='tab-'+k);document.querySelectorAll('nav button').forEach(b=>b.setAttribute('aria-selected',String(b.dataset.tab===k)));};
document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{show(b.dataset.tab);history.replaceState(null,'','#'+b.dataset.tab);});
addEventListener('hashchange',()=>show(location.hash.slice(1)));
show(location.hash.slice(1));
</script></body></html>
`;
writeFileSync(join(work, "board.html"), html);
console.log(join(work, "board.html"));
