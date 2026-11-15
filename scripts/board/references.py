"""레퍼런스 보드를 Harness Board 안에서 보이고 고르게 한다(표준 라이브러리만).

design-refs.sh board가 그릴 때마다 남기는 실행 기록(<data>/board/references/<run-id>.json, 형식은
skills/design-references/SKILL.md의 "Run record")을 읽어 목록·상세를 만든다. 실행마다 따로 뜨던 보드 서버
(landing-board-server.mjs) 없이도 대시보드에서 레퍼런스 보드를 보게 하려는 것이다.

- 파일 서빙: 등록된 실행 기록의 작업 폴더 안, refs/·captures/ 아래 이미지·영상만. realpath로 정규화해 작업 폴더
  밖(.. ·심볼릭 링크)으로 나가면 거부한다.
- 고르기: 작업 폴더의 랜딩 실행(.landing-run/state.json)이 reference_pick에 있을 때만. 검사·쓰기·기록 갱신은
  landing-pick.mjs(보드 서버와 같은 명령)가 한다 — 같은 규칙을 두 곳에 두지 않는다.
"""
import json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PICK_CMD = os.path.join(ROOT, "landing-pick.mjs")
RUN_ID = re.compile(r"^[0-9a-f]{12}$")
KINDS = ("tone", "component", "layout", "interaction", "competitor")
MEDIA_DIRS = ("refs", "captures")
MEDIA_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
               ".webm": "video/webm", ".mp4": "video/mp4"}


def _json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


class Store:
    def __init__(self, data_dir):
        self.dir = os.path.join(data_dir, "board", "references")

    # ---- 실행 기록 ----
    def record(self, run_id):
        if not isinstance(run_id, str) or not RUN_ID.match(run_id):
            return None
        rec = _json(os.path.join(self.dir, run_id + ".json"))
        if not isinstance(rec, dict) or not isinstance(rec.get("work"), str) or not os.path.isabs(rec["work"]):
            return None
        rec["run_id"] = run_id
        return rec

    def records(self):
        try:
            names = sorted(n for n in os.listdir(self.dir) if n.endswith(".json"))
        except OSError:
            return []
        out = [self.record(n[:-5]) for n in names]
        return [r for r in out if r]

    @staticmethod
    def _landing(work):
        """작업 폴더의 랜딩 실행: {node, picked, since} 또는 None(실행 없음). reference_pick이면 그 노드에서 이미
        골랐는지는 landing-pick.mjs state가 판단한다(보드 서버와 같은 규칙)."""
        st = _json(os.path.join(work, ".landing-run", "state.json"))
        if not isinstance(st, dict):
            return None
        node, picked = st.get("node"), False
        if node == "reference_pick":
            try:
                out = subprocess.run(["node", PICK_CMD, "state", "--work", work, "--node", "reference_pick"],
                                     capture_output=True, text=True, timeout=15)
                picked = json.loads(out.stdout).get("picked") is not None
            except (OSError, ValueError, subprocess.TimeoutExpired):
                return {"node": node, "picked": True, "since": st.get("entered_at")}  # 판단 못 하면 고르기를 열지 않는다
        return {"node": node, "picked": picked, "since": st.get("entered_at")}

    def summary(self, rec):
        work = rec["work"]
        missing = not os.path.isdir(work)
        refs = [] if missing else (_json(os.path.join(work, "references.json")) or [])
        counts = {k: 0 for k in KINDS}
        for r in refs if isinstance(refs, list) else []:
            if isinstance(r, dict) and r.get("kind") in counts:
                counts[r["kind"]] += 1
        landing = None if missing else self._landing(work)
        return {"run_id": rec["run_id"], "topic": rec.get("topic") or os.path.basename(work), "work": work,
                "status": "picked" if rec.get("status") == "picked" else "ready",
                "created_at": rec.get("created_at"), "updated_at": rec.get("updated_at"),
                "missing": missing, "counts": counts, "landing_node": landing and landing["node"],
                "landing_since": landing and landing["since"],
                "can_pick": bool(landing and landing["node"] == "reference_pick" and not landing["picked"])}

    def listing(self):
        out = [self.summary(r) for r in self.records()]
        out.sort(key=lambda x: str(x.get("created_at") or ""), reverse=True)
        return out

    # ---- 상세 ----
    def _media(self, work, run_id, src):
        """보드에 실을 매체 주소: 원격 http(s)는 그대로, 작업 폴더 안 파일은 /references/file 경로, 그 밖은 버린다."""
        s = str(src or "")
        if re.match(r"^https?://", s, re.I):
            return {"remote": s}
        rel = re.sub(r"^\./", "", s)
        if os.path.isabs(s):
            real = os.path.realpath(work)
            rel = os.path.relpath(os.path.realpath(s), real) if os.path.realpath(s).startswith(real + os.sep) else ".."
        if rel.startswith("..") or not self.media_path(run_id, rel):
            return None
        return {"path": rel}

    def detail(self, run_id):
        rec = self.record(run_id)
        if not rec:
            return None
        head = self.summary(rec)
        if head["missing"]:
            return {**head, "refs": [], "tone": None, "slots": [], "picked": None}
        work = rec["work"]
        refs = _json(os.path.join(work, "references.json"))
        out = []
        for r in refs if isinstance(refs, list) else []:
            if not isinstance(r, dict) or r.get("kind") not in KINDS:
                continue
            caps = [m for m in (self._media(work, run_id, c) for c in (r.get("captures") or [])[:12]) if m]
            video = self._media(work, run_id, r.get("video")) if r.get("video") else None
            keep = {k: r.get(k) for k in ("id", "kind", "title", "url", "source", "take", "tone_part", "keep_strength",
                                         "must_not_shrink_to", "recommended", "analysis") if r.get(k) is not None}
            out.append({**keep, "captures": caps, "video": video})
        slots = _json(os.path.join(work, "component-slots.json"))
        slots = [{"id": s.get("id"), "label": s.get("label")} for s in slots if isinstance(s, dict)] if isinstance(slots, list) else []
        tone = _json(os.path.join(work, "tone.json"))
        picked = _json(os.path.join(work, "reference-pick.json")) if head["landing_node"] and not head["can_pick"] else None
        return {**head, "refs": out, "tone": tone if isinstance(tone, dict) else None, "slots": slots, "picked": picked}

    # ---- 파일 서빙(보안) ----
    def media_path(self, run_id, rel):
        """등록된 실행 기록의 작업 폴더 안 refs/·captures/ 아래 이미지·영상의 실제 경로. 아니면 None."""
        rec = self.record(run_id)
        if not rec or not isinstance(rel, str) or not rel or len(rel) > 1024 or "\x00" in rel or os.path.isabs(rel):
            return None
        parts = rel.replace("\\", "/").split("/")
        if parts[0] not in MEDIA_DIRS or any(p in ("", ".", "..") or p.startswith(".") for p in parts):
            return None
        if os.path.splitext(parts[-1])[1].lower() not in MEDIA_TYPES:
            return None
        try:
            base = os.path.realpath(rec["work"])
            real = os.path.realpath(os.path.join(base, *parts))
        except (OSError, ValueError):
            return None
        allowed = tuple(os.path.join(base, d) + os.sep for d in MEDIA_DIRS)
        if not real.startswith(allowed) or not os.path.isfile(real):
            return None
        if os.path.splitext(real)[1].lower() not in MEDIA_TYPES:  # 링크가 다른 확장자 파일을 가리키는 경우
            return None
        return real

    @staticmethod
    def media_type(path):
        return MEDIA_TYPES[os.path.splitext(path)[1].lower()]

    # ---- 고르기 ----
    def pick(self, run_id, body):
        """landing-pick.mjs write로 reference-pick.json을 쓴다. (HTTP 상태, 응답)."""
        rec = self.record(run_id)
        if not rec:
            return 404, {"ok": False, "message": "등록된 레퍼런스 실행이 아님"}
        if not os.path.isdir(rec["work"]):
            return 409, {"ok": False, "message": "작업 폴더가 없어 고를 수 없음"}
        landing = self._landing(rec["work"])
        if not landing:
            return 409, {"ok": False, "message": "진행 중인 랜딩 실행이 없어 보기 전용임"}
        payload = {k: body.get(k) for k in ("tone", "kept", "dropped", "add_sites", "primary", "user_words") if k in body}
        payload["node"] = "reference_pick"
        try:
            out = subprocess.run(["node", PICK_CMD, "write", "--work", rec["work"], "--run-id", run_id],
                                 input=json.dumps(payload), capture_output=True, text=True, timeout=30)
            res = json.loads(out.stdout.strip().splitlines()[-1])
        except (OSError, ValueError, IndexError, subprocess.TimeoutExpired) as e:
            return 500, {"ok": False, "message": f"고른 내용을 쓰지 못함: {e}"}
        status = res.pop("status", 500)
        if status == 200:
            return 200, {"ok": True, "message": "받았어요. 세션이 이어서 진행해요.", "file": res.get("file")}
        if status == 409:
            return 409, {"ok": False, "error": "already_started", "node": res.get("node"),
                         "message": "이미 시작된 단계라 다시 보내지 않았어요."}
        return status, {"ok": False, "message": res.get("error") or "고른 내용이 올바르지 않음"}

    # ---- 지금 할 일 ----
    def todo_items(self):
        """랜딩 실행이 reference_pick에서 기다리는 보드: '지금 할 일' 카드(주 동작은 열기)."""
        items = []
        for s in self.listing():
            if not s["can_pick"]:
                continue
            items.append({"id": "refs:" + s["run_id"], "section": "harness", "kind": "references", "state": "needs_human",
                          "title": f"레퍼런스 고르기 — {s['topic']}", "project": os.path.basename(s["work"].rstrip("/")) or "레퍼런스",
                          "at": s["landing_since"] or s["updated_at"], "run_id": s["run_id"],
                          "detail": "랜딩 실행이 레퍼런스 고르기에서 기다립니다. 열어서 대표를 고르고 시작하세요."})
        return items
