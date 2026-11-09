#!/usr/bin/env node
// /landing-page board: render the boards the user picks from, so no agent writes their HTML.
//   node landing-board.mjs --work DIR [--kind references]  → DIR/board.html: five tabs (tone and manner, components,
//        layout, interaction, competitors) from tone.json and references.json, a keep/drop toggle per reference
//   node landing-board.mjs --work DIR --kind drafts        → DIR/draft-board.html: each candidate's first viewport at
//        1440 and 390 (preview-<id>.json) with its first_viewport line, one to go ahead with
// Served by landing-board-server.mjs, the start button writes reference-pick.json or draft-pick.json; served statically,
// the board shows a summary to paste into the terminal instead. Media paths stay relative to DIR.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative, isAbsolute } from "node:path";

const argv = process.argv.slice(2);
const opt = (k) => (argv.indexOf(k) >= 0 ? argv[argv.indexOf(k) + 1] : "");
const work = opt("--work");
const kind = opt("--kind") || "references";
if (!work || !["references", "drafts"].includes(kind)) {
  console.error("usage: landing-board.mjs --work DIR [--kind references|drafts]");
  process.exit(2);
}
const read = (f) => JSON.parse(readFileSync(join(work, f), "utf8"));

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
const link = (u) => (remote(u) ? `<a href="${esc(u)}" target="_blank" rel="noopener">${esc(u)}</a>` : `<span class="src">${esc(u)}</span>`);

function shots(r) {
  const caps = (r.captures ?? []).map(media).filter(Boolean).map((c) => `<img src="${esc(c)}" alt="${esc(r.title ?? r.id)} 캡처" loading="lazy">`);
  const v = r.video ? media(r.video) : "";
  const video = v ? `<video src="${esc(v)}" muted loop autoplay playsinline></video>` : "";
  return caps.length || video ? `<div class="shots">${video}${caps.join("")}</div>` : `<p class="missing">캡처 없음</p>`;
}

const CSS = `:root{--bg:#f6f6f4;--card:#fff;--ink:#18191b;--sub:#6b6d70;--line:#e3e3e0;--accent:#c24e00}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 -apple-system,"Apple SD Gothic Neo","Pretendard",system-ui,sans-serif;padding-bottom:150px}
header.top{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:16px clamp(16px,4vw,40px) 0}
h1{font-size:20px;margin:0 0 4px}.ask{color:var(--sub);margin:0 0 12px;font-size:14px}
nav{display:flex;gap:4px;overflow-x:auto}nav button{font:inherit;border:0;background:none;padding:10px 14px;border-bottom:3px solid transparent;cursor:pointer;color:var(--sub);white-space:nowrap}
nav button small{margin-left:6px}nav button[aria-selected=true]{color:var(--ink);border-color:var(--accent);font-weight:700}
button:focus-visible,input:focus-visible,textarea:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
main{padding:20px clamp(16px,4vw,40px) 40px;max-width:1400px}
article{background:var(--card);border-radius:14px;padding:20px;margin:0 0 18px;border:1px solid var(--line);transition:opacity .15s}
article.dropped{opacity:.45}
article header{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:baseline;margin-bottom:12px}article h3{margin:0;font-size:17px}
.id{font-weight:700;color:var(--accent)}article a{color:#2a62d6;font-size:13px;word-break:break-all}.src{color:var(--sub);font-size:13px}
.keep{margin-left:auto;font:inherit;font-size:14px;font-weight:600;border:1px solid var(--ink);background:var(--ink);color:#fff;border-radius:999px;padding:4px 14px;cursor:pointer}
.keep[aria-pressed=false]{background:#fff;color:var(--sub);border-color:var(--line)}
.shots{display:flex;gap:10px;overflow-x:auto;margin-bottom:12px}.shots img,.shots video{height:300px;max-width:100%;object-fit:contain;border-radius:8px;border:1px solid var(--line);background:#eee;flex:none}
p{margin:6px 0}.tag{display:inline-block;background:#fff3e8;color:#8a3b00;border-radius:999px;padding:2px 10px;font-size:13px}
.missing{color:var(--sub)}.analysis{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;margin:0 0 10px;font-size:14px}.analysis dt{color:var(--sub)}.analysis dd{margin:0}
.tone{background:var(--card);border-radius:14px;padding:24px;border:1px solid var(--line);margin-bottom:18px}
.mood{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px}.mood span{font-size:22px;font-weight:700;padding:4px 14px;border-radius:999px;background:#f1f1ee}
.avoid{color:#a12a2a}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:24px;margin-top:16px}h4{margin:0 0 8px;font-size:13px;color:var(--sub)}
.palette{list-style:none;padding:0;margin:0;display:grid;gap:8px}.palette li{display:grid;grid-template-columns:32px auto 1fr;gap:2px 10px;align-items:center}
.chip{width:32px;height:32px;border-radius:8px;border:1px solid var(--line);grid-row:span 2}.palette code{font-size:12px;color:var(--sub)}.palette small{grid-column:2/4;color:var(--sub)}
.type-display{font-size:28px;font-weight:800;line-height:1.25;margin:0 0 6px}.type-body{margin:0 0 6px}blockquote{margin:0 0 12px;padding:8px 12px;border-left:3px solid var(--accent);background:#fafaf8}
.tone-answer{margin-top:18px;padding-top:16px;border-top:1px solid var(--line);display:grid;gap:8px}.tone-answer label{display:flex;gap:8px;align-items:center}
textarea,input[type=text]{font:inherit;width:100%;border:1px solid var(--line);border-radius:8px;padding:8px 10px;background:#fff}
.go{display:flex;gap:8px;align-items:center;margin-top:8px;font-weight:600}
footer.pick{position:fixed;left:0;right:0;bottom:0;z-index:3;background:#fff;border-top:1px solid var(--line);padding:12px clamp(16px,4vw,40px);display:grid;grid-template-columns:1fr 1fr auto;gap:10px;align-items:end;box-shadow:0 -6px 20px rgba(0,0,0,.05)}
footer.pick label{font-size:13px;color:var(--sub);display:grid;gap:4px}
.start{font:inherit;font-weight:700;border:0;background:var(--accent);color:#fff;border-radius:10px;padding:12px 20px;cursor:pointer;white-space:nowrap}
.start:disabled{opacity:.5;cursor:default}.count{font-size:13px;color:var(--sub);grid-column:1/-1}
.static{grid-column:1/-1;display:grid;gap:6px}.static[hidden]{display:none}.static b{color:var(--accent)}
.done{grid-column:1/-1;font-weight:700;color:#1d7a3a}.err{grid-column:1/-1;color:#a12a2a}
@media (max-width:700px){.shots img,.shots video{height:220px}.analysis{grid-template-columns:1fr}.analysis dd{margin-bottom:6px}footer.pick{grid-template-columns:1fr}body{padding-bottom:300px}}`;

// The pick bar: a live server (GET /pick answers) takes the start button; otherwise the user answers in the terminal.
const PICK_JS = `
const bar=document.querySelector('footer.pick'),btn=bar.querySelector('.start'),stat=bar.querySelector('.static'),out=bar.querySelector('.summary');
const say=(cls,t)=>{bar.querySelectorAll('.done,.err').forEach(e=>e.remove());const p=document.createElement('p');p.className=cls;p.textContent=t;bar.append(p);};
const refresh=()=>{const s=summary();out.value=s.text;bar.querySelector('.count').textContent=s.count;btn.disabled=!s.ready;};
fetch('pick',{cache:'no-store'}).then(r=>r.ok?r.json():null).then(j=>{if(!(j&&j.server))throw 0;btn.hidden=false;}).catch(()=>{btn.hidden=true;stat.hidden=false;});
btn.onclick=async()=>{btn.disabled=true;try{const r=await fetch('pick',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload())});const j=await r.json();if(!r.ok)throw new Error(j.error||r.status);say('done','받았어요. 세션이 이어서 진행해요.');}catch(e){say('err','보내지 못했어요: '+e.message+' — 아래 요약을 터미널에 붙여 주세요.');stat.hidden=false;btn.disabled=false;}};
bar.querySelector('.copy').onclick=()=>{out.select();navigator.clipboard?.writeText(out.value);};
document.addEventListener('input',refresh);document.addEventListener('change',refresh);document.addEventListener('click',()=>setTimeout(refresh));refresh();`;

const pickBar = (startLabel, extra) => `<footer class="pick" aria-label="고르기">
${extra}<button class="start" type="button" hidden>${startLabel}</button>
<p class="count"></p>
<div class="static" hidden><p><b>터미널에 답해 주세요.</b> 보드 서버 없이 열려 있어 여기서 바로 시작할 수 없어요. 아래 요약을 복사해 붙여 넣으면 돼요.</p>
<textarea class="summary" rows="3" readonly></textarea><div><button class="copy" type="button">요약 복사</button></div></div></footer>`;

const page = (title, ask, body, script) => `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>${CSS}</style></head><body>
${body}
<script>${script}${PICK_JS}</script></body></html>
`;

function referencesBoard() {
  const tone = existsSync(join(work, "tone.json")) ? read("tone.json") : {};
  const refs = read("references.json");
  if (!Array.isArray(refs)) {
    console.error("references.json must be an array");
    process.exit(4);
  }
  const TABS = [["tone", "톤앤매너"], ["component", "구성요소"], ["layout", "레이아웃"], ["interaction", "인터랙션"], ["competitor", "경쟁사 분석"]];
  const card = (r) => {
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
    return `<article id="${esc(r.id)}"><header><span class="id">${esc(r.id)}</span><h3>${esc(r.title)}</h3>
${link(r.url)}<span class="src">${esc(r.source)}</span><button class="keep" type="button" aria-pressed="true" data-id="${esc(r.id)}">남김</button></header>
${shots(r)}${analysis}${lines.join("")}</article>`;
  };
  const toneHead = () => {
    if (!tone.mood) return `<p class="missing">tone.json이 없어요. brief의 Tone and manner를 tone.json으로도 내 주세요.</p>`;
    const chips = (tone.palette ?? [])
      .map((p) => `<li><span class="chip" style="background:${esc(hex(p.hex))}"></span><b>${esc(p.name)}</b><code>${esc(p.hex)}</code><small>${esc(p.role)}</small></li>`)
      .join("");
    const type = tone.type ?? {};
    return `<section class="tone">
<div class="mood">${(tone.mood ?? []).map((m) => `<span>${esc(m)}</span>`).join("")}</div>
${tone.avoid ? `<p class="avoid"><b>피할 느낌</b> ${esc(tone.avoid)}</p>` : ""}
<div class="grid"><div><h4>색</h4><ul class="palette">${chips}</ul></div>
<div><h4>서체</h4><p class="type-display">${esc(type.display_sample)}</p><p class="type-body">${esc(type.body_sample)}</p><small>${esc(type.display)} · ${esc(type.body)}</small></div>
<div><h4>말투</h4><blockquote>${esc(tone.voice)}</blockquote><h4>이미지</h4><p>${esc(tone.imagery)}</p></div></div>
<div class="tone-answer"><h4>이 톤앤매너로 갈까요?</h4>
<label><input type="radio" name="tone" value="keep" checked> 이대로</label>
<label><input type="radio" name="tone" value="change"> 바꿀 점이 있어요</label>
<textarea id="tone-change" rows="2" placeholder="바꿀 점 (예: 더 따뜻하게, 오렌지를 더 써도 돼요)"></textarea></div></section>`;
  };
  const of = (k) => refs.filter((r) => r.kind === k);
  const panels = TABS.map(([k]) => {
    const cards = of(k).map(card).join("");
    const body = (k === "tone" ? toneHead() : "") + (cards || `<p class="missing">이 탭의 레퍼런스가 없어요.</p>`);
    return `<section class="panel" id="tab-${k}" role="tabpanel" hidden>${body}</section>`;
  }).join("");
  const nav = TABS.map(([k, label]) => `<button role="tab" data-tab="${k}" aria-controls="tab-${k}">${label}<small>${of(k).length || ""}</small></button>`).join("");
  const body = `<header class="top"><h1>레퍼런스 보드</h1><p class="ask">톤앤매너는 이대로 갈지, 탭마다 남길 것과 뺄 것, 더 보고 싶은 사이트를 골라 주세요. 다 고르면 아래 「이 레퍼런스로 시작」을 누르면 돼요.</p>
<nav role="tablist">${nav}</nav></header><main>${panels}</main>
${pickBar("이 레퍼런스로 시작", `<label>추가로 볼 사이트 (URL, 여러 개면 줄바꿈)<textarea id="add-sites" rows="1" placeholder="https://"></textarea></label>
<label>하고 싶은 말<textarea id="memo" rows="1" placeholder="예: 3D는 과하지 않게"></textarea></label>`)}`;
  const script = `
const keys=${JSON.stringify(TABS.map(([k]) => k))};
const show=(k)=>{if(!keys.includes(k))k=keys[0];document.querySelectorAll('.panel').forEach(p=>p.hidden=p.id!=='tab-'+k);document.querySelectorAll('nav button').forEach(b=>b.setAttribute('aria-selected',String(b.dataset.tab===k)));};
document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{show(b.dataset.tab);history.replaceState(null,'','#'+b.dataset.tab);});
addEventListener('hashchange',()=>show(location.hash.slice(1)));show(location.hash.slice(1));
document.querySelectorAll('.keep').forEach(b=>b.onclick=()=>{const on=b.getAttribute('aria-pressed')!=='true';b.setAttribute('aria-pressed',String(on));b.textContent=on?'남김':'뺌';b.closest('article').classList.toggle('dropped',!on);});
const val=(id)=>(document.getElementById(id)?.value||'').trim();
const payload=()=>{const kept=[],dropped=[];document.querySelectorAll('.keep').forEach(b=>(b.getAttribute('aria-pressed')==='true'?kept:dropped).push(b.dataset.id));
const change=document.querySelector('input[name=tone][value=change]')?.checked;const tc=val('tone-change');
return {node:'reference_pick',tone:change&&tc?'바꿀 점: '+tc:'이대로',kept,dropped,add_sites:val('add-sites').split(/\\s+/).filter(u=>/^https?:\\/\\//i.test(u)),user_words:[change?tc:'',val('memo')].filter(Boolean).join('\\n')};};
const summary=()=>{const p=payload();return {ready:p.kept.length>0,count:'남김 '+p.kept.length+' · 뺌 '+p.dropped.length,
text:'톤앤매너: '+p.tone+'\\n남김: '+(p.kept.join(', ')||'없음')+'\\n뺌: '+(p.dropped.join(', ')||'없음')+(p.add_sites.length?'\\n추가로 볼 사이트: '+p.add_sites.join(' '):'')+(val('memo')?'\\n하고 싶은 말: '+val('memo'):'')};};`;
  return ["board.html", page("레퍼런스 보드", "", body, script)];
}

function draftsBoard() {
  const cands = read("candidates.json").candidates ?? [];
  const card = (c) => {
    const pf = join(work, `preview-${c.id}.json`);
    const prev = existsSync(pf) ? JSON.parse(readFileSync(pf, "utf8")) : {};
    return `<article id="${esc(c.id)}"><header><span class="id">${esc(c.id)}</span><h3>${esc(c.first_viewport)}</h3>
${prev.url ? link(prev.url) : ""}<span class="src">모션 ${esc(c.motion_level)}</span></header>
${shots({ id: c.id, captures: prev.captures ?? [] })}
${c.visitor_action ? `<p><b>방문자가 해 보는 것</b> ${esc(c.visitor_action)}</p>` : ""}
<label class="go"><input type="radio" name="draft" value="${esc(c.id)}"> 이 안으로 진행</label></article>`;
  };
  const body = `<header class="top"><h1>첫 화면 시안</h1><p class="ask">안마다 PC(1440)와 폰(390) 첫 화면이에요. 진행할 안 하나를 고르고, 바꿀 점이 있으면 적어 주세요.</p></header>
<main>${cands.map(card).join("") || `<p class="missing">candidates.json에 후보가 없어요.</p>`}</main>
${pickBar("이 안으로 진행", `<label style="grid-column:span 2">메모<textarea id="memo" rows="1" placeholder="예: B로 가되 제목은 A처럼"></textarea></label>`)}`;
  const script = `
const ids=${JSON.stringify(cands.map((c) => c.id))};
const val=(id)=>(document.getElementById(id)?.value||'').trim();
const payload=()=>{const k=document.querySelector('input[name=draft]:checked')?.value;return {node:'draft_pick',kept:k?[k]:[],dropped:ids.filter(i=>i!==k),user_words:val('memo')};};
const summary=()=>{const p=payload();return {ready:p.kept.length===1,count:p.kept.length?p.kept[0]+' 안으로 진행':'진행할 안을 골라 주세요',
text:'진행할 안: '+(p.kept[0]||'미정')+(p.user_words?'\\n메모: '+p.user_words:'')};};`;
  return ["draft-board.html", page("첫 화면 시안", "", body, script)];
}

const [file, html] = kind === "drafts" ? draftsBoard() : referencesBoard();
writeFileSync(join(work, file), html);
console.log(join(work, file));
