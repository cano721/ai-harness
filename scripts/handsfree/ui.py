"""상태 화면과 설정. 듣기 프로그램 안에서 이 맥에서만 열리는 작은 웹 서버로 돈다.

화면에서 바꿀 수 있는 건 아래 SETTINGS, 호출어, 세션 별명이다. 명령 말 목록은 잘못 바꾸면 안전 규칙이
깨지므로 설정 파일로만 고친다. 호출어는 너무 짧거나 명령 말과 겹치면 받지 않는다.
"""
import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import common
import orca

PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui.html")
# 화면에 보일 순서와 이름. 여기 없는 동작은 표에 나오지 않는다.
GROUPS = [
    ("승인 창", [("approve", "승인"), ("deny", "거절"), ("approve_force", "위험 명령 승인"),
              ("explain_dialog", "창 내용 읽기")]),
    ("멈추기", [("interrupt", "작업 중단"), ("undo", "방금 보낸 것 중단")]),
    ("긴 말", [("dictate", "긴 말 모드 시작")]),
    ("세션", [("next_session", "다음 세션"), ("prev_session", "이전 세션"), ("current_session", "현재 세션 확인"),
            ("list_sessions", "세션 목록"), ("status_all", "세션 상태")]),
    ("읽어 주기", [("read_last", "답변 읽기"), ("read_summary", "요약해서 읽기"), ("read_more", "이어서 읽기"), ("read_all", "전부 읽기"),
               ("stop_speaking", "읽기 멈춤"), ("tts_on", "답변 자동 읽기 켜기"), ("tts_off", "답변 자동 읽기 끄기")]),
    ("듣기", [("pause", "쉬기"), ("resume", "다시 듣기"), ("ping", "듣고 있는지 확인")]),
    ("그 밖", [("open_ui", "이 화면 열기"), ("confirm_on", "보내기 전 확인 켜기"), ("confirm_off", "보내기 전 확인 끄기"),
             ("enter", "엔터 누르기")]),
]
PATTERNS = [
    ("그 밖의 말", "지금 세션에 프롬프트로 보내기"),
    ("1번 · 3번 · 두 번째", "선택지 고르기"),
    ("3번 세션", "그 세션으로 이동"),
    ("3번 세션에 ~해 줘", "이동하지 않고 그 세션에만 보내기"),
    ("3번 세션 승인", "그 세션의 승인 창에 답하기"),
    ("(탭 이름) 세션", "이름으로 이동"),
    ("5분 쉬어", "그 시간만큼 쉬기"),
    ("(별명)에 ~해 줘 · (별명)로 가 · (별명) 승인", "별명으로 세션 부르기"),
    ("긴 말 모드에서 보내 · 끝 / 취소", "모아서 보내기 / 버리기"),
    ("3번 끝나면 알려 줘 · (별명) 끝나면 알려 줘", "끝나거나 승인이 필요하면 한 번 알림"),
]
SETTINGS = [
    ("듣기", [
        {"key": "silence_sec", "label": "말 끝 기다림", "unit": "초", "min": 0.5, "max": 2.5, "step": 0.1,
         "help": "말이 멈추고 이만큼 조용하면 끝난 것으로 봅니다. 짧을수록 빠르지만 잠깐 멈춘 곳에서 끊깁니다."},
        {"key": "mic_threshold", "label": "마이크 기준선", "unit": "%", "min": 0.5, "max": 6, "step": 0.1,
         "help": "이보다 큰 소리가 나면 듣기 시작합니다. 낮추면 작은 목소리도 잡고, 높이면 주변 소리를 덜 잡습니다."},
        {"key": "pre_roll_sec", "label": "첫마디 여유", "unit": "초", "min": 0.2, "max": 1.0, "step": 0.05,
         "help": "듣기 시작하기 직전 소리를 이만큼 더 붙여 받아씁니다. 첫마디(헤이)가 자주 빠지면 늘리세요."},
        {"key": "wake_window_sec", "label": "부른 뒤 기다림", "unit": "초", "min": 3, "max": 20, "step": 1,
         "help": "호출어만 부른 뒤 이어서 말할 수 있는 시간입니다."},
        {"key": "max_utterance_sec", "label": "한 번에 말할 수 있는 길이", "unit": "초", "min": 10, "max": 60, "step": 5,
         "help": "이보다 길면 잘린 것으로 보고 보내지 않습니다. 길게 말할 때는 ‘길게 말할게’로 시작하세요."},
    ]),
    ("보내기", [
        {"key": "confirm_before_send", "label": "보내기 전 확인", "type": "bool",
         "help": "프롬프트를 보내기 전에 받아쓴 내용을 읽어 주고 ‘보내’를 기다립니다."},
        {"key": "confirm_window_sec", "label": "대답 기다리는 시간", "unit": "초", "min": 10, "max": 60, "step": 5,
         "help": "‘보낼까요?’라고 물은 뒤 대답을 기다리는 시간입니다. 지나면 보내지 않습니다."},
        {"key": "dictation_idle_sec", "label": "긴 말 모드 자동 마침", "unit": "초", "min": 10, "max": 120, "step": 5,
         "help": "긴 말 모드에서 이만큼 말이 없으면 받아쓴 내용을 보낼지 묻습니다."},
        {"key": "follow_keyboard", "label": "키보드로 입력한 세션 따라가기", "type": "bool",
         "help": "키보드로 프롬프트를 친 세션으로 음성 입력 대상을 옮깁니다."},
        {"key": "follow_focus", "label": "화면에서 고른 세션 따라가기", "type": "bool",
         "help": "Orca 에서 탭을 클릭해 앞에 띄우면 그 세션으로 음성 입력 대상을 옮깁니다. 화면을 여러 칸으로 나눠 보고 있으면 따라가지 않습니다."},
        {"key": "ai_fallback", "label": "승인 창 AI 판단", "type": "bool",
         "help": "승인 창이 떠 있을 때 정해진 말이 아니면 AI 가 뜻을 짐작하고 한 번 되묻습니다. 끄면 승인·거절·번호만 알아듣습니다."},
    ]),
    ("읽어 주기", [
        {"key": "tts", "label": "답변 자동으로 읽기", "type": "bool",
         "help": "답변이 끝나거나 승인이 필요하면 소리로 알려 줍니다."},
        {"key": "tts_summary", "label": "요약해서 읽기", "type": "bool",
         "help": "자동으로 읽을 때 원문 대신 두 문장 요약을 읽습니다(7~8초 늦어짐). 자동 읽기가 꺼져 있어도 ‘요약해 줘’라고 하면 요약해 읽습니다."},
        {"key": "tts_other_sessions", "label": "다른 세션 알림", "type": "bool",
         "help": "다른 세션이 끝나거나 승인을 기다리면 번호로 알려 줍니다."},
        {"key": "tts_rate", "label": "읽는 속도", "unit": "", "min": 140, "max": 320, "step": 10,
         "help": "클수록 빨리 읽습니다. 기본은 210입니다."},
        {"key": "tts_max_chars", "label": "한 번에 읽는 길이", "unit": "자", "min": 80, "max": 800, "step": 20,
         "help": "요약하지 않을 때 앞에서부터 읽는 길이입니다. ‘계속 읽어 줘’로 다음을 듣습니다."},
    ]),
    ("소리", [
        {"key": "speech_volume", "label": "읽는 소리 크기", "unit": "%", "min": 0, "max": 100, "step": 5, "percent": True,
         "help": "답변과 안내를 읽는 소리입니다. 0이면 읽지 않고 알림만 띄웁니다."},
        {"key": "beep_volume", "label": "효과음 크기", "unit": "%", "min": 0, "max": 100, "step": 5, "percent": True,
         "help": "알아들었을 때(뽁), 보냈을 때(팅), 하지 않았을 때(낮은 소리) 나는 짧은 소리입니다."},
        {"key": "quiet_hours", "label": "조용한 시간", "type": "bool",
         "help": "정한 시간대에는 소리를 작게 냅니다. 아예 끄지 않는 건, 하지 않은 일은 소리로 알려야 해서입니다."},
        {"key": "quiet_from", "label": "조용한 시간 시작", "unit": "시", "min": 0, "max": 23, "step": 1,
         "help": "이 시각부터 작게 냅니다."},
        {"key": "quiet_to", "label": "조용한 시간 끝", "unit": "시", "min": 0, "max": 23, "step": 1,
         "help": "이 시각에 원래 크기로 돌아옵니다. 시작보다 이른 시각이면 다음 날로 봅니다(예: 22시~7시)."},
        {"key": "quiet_volume", "label": "조용한 시간 소리 크기", "unit": "%", "min": 0, "max": 100, "step": 5, "percent": True,
         "help": "조용한 시간에 내는 가장 큰 소리입니다."},
    ]),
]
FIELDS = {f["key"]: f for _, fields in SETTINGS for f in fields}
LINE = re.compile(r"^(\d\d-\d\d) (\d\d:\d\d:\d\d) (.*)$")
watch = {"seen": 0, "sessions": [], "at": 0}


def refresh_sessions():
    """화면을 보는 사람이 있을 때만 세션 상태를 읽는다. 세션 수만큼 Orca 를 불러 가볍지 않다."""
    while True:
        time.sleep(1)
        if time.time() - watch["seen"] > 6 or time.time() - watch["at"] < 3:
            continue
        try:
            items = orca.sessions()
            with ThreadPoolExecutor(max_workers=8) as pool:
                screens = list(pool.map(lambda s: orca.screen(s["handle"]), items))
            current = common.load_state().get("current")
            rows = []
            for i, (s, text) in enumerate(zip(items, screens)):
                dlg = orca.dialog(text)
                ask = ""
                if dlg:
                    record = common.read_json(common.session_file(s["handle"]), {})
                    fresh = time.time() - record.get("pending_at", 0) < 600
                    ask = (record.get("pending") if fresh else "") or dlg["ask"]
                rows.append({"number": i + 1, "name": orca.label(s), "state": orca.state_of(text),
                             "current": s["handle"] == current, "ask": ask})
            watch["sessions"] = rows
        except Exception as exc:
            common.log("화면용 세션 읽기 오류: %r" % exc)
        watch["at"] = time.time()


def recent_events(count=80):
    """기록을 "들은 말 하나 + 그 결과들" 묶음으로. 최신이 앞."""
    try:
        with open(common.LOG_PATH, encoding="utf-8") as f:
            lines = f.readlines()[-count:]
    except OSError:
        return []
    groups, current = [], None
    for line in lines:
        m = LINE.match(line.rstrip("\n"))
        if not m:
            continue
        stamp, rest = m.group(2), m.group(3)
        if rest.startswith(("→ ", "✕ ")):
            result = {"ok": rest.startswith("→"), "text": rest[2:]}
            if current is not None:
                current["results"].append(result)
            else:
                groups.append({"time": stamp, "kind": "result", "results": [result]})
            continue
        if " ← " in rest:
            action, text = rest.split(" ← ", 1)
            name = action.split(" ")[0]
            if name == "ignore":
                # 잡음이 받아써진 것들이 이어지면 한 줄로 접는다.
                last = groups[-1] if groups else None
                if last and last["kind"] == "ignored":
                    last["count"] += 1
                    last["time"] = stamp
                    if text not in last["texts"]:
                        last["texts"].append(text)
                else:
                    groups.append({"time": stamp, "since": stamp, "kind": "ignored", "count": 1, "texts": [text]})
                current = None
                continue
            current = {"time": stamp, "kind": "heard", "action": name, "armed": "(대기 중)" in action,
                       "paused": "(쉬는 중)" in action, "text": text, "results": []}
            groups.append(current)
            continue
        if rest.startswith("ai "):
            continue
        groups.append({"time": stamp, "kind": "note", "text": rest})
        current = None
    return list(reversed(groups[-30:]))


def defaults():
    return common.read_json(os.path.join(common.CODE_DIR, "defaults.json"), {})


def as_number(key, value):
    if key == "mic_threshold":
        return float(str(value).rstrip("%"))
    if FIELDS.get(key, {}).get("percent") and value is not None:
        return int(round(float(value) * 100))
    return value


def settings_view():
    cfg, base = common.load_config(), defaults()
    groups = []
    for title, fields in SETTINGS:
        rows = []
        for field in fields:
            value, default = as_number(field["key"], cfg.get(field["key"])), as_number(field["key"], base.get(field["key"]))
            rows.append(dict(field, value=value, default=default))
        groups.append({"title": title, "fields": rows})
    return {"groups": groups, "aliases": cfg.get("aliases", {}), "macros": cfg.get("macros", {}),
            "wake_suggestions": wake_suggestions(cfg), "wake_words": cfg["wake_words"],
            "wake_default": base.get("wake_words", [])[:1], "wake_is_default": cfg["wake_words"] == base.get("wake_words")}


def validate(changes, cfg):
    """화면에서 온 값을 확인해 저장할 dict 로. 틀리면 ValueError(사람이 읽을 문장)."""
    if not isinstance(changes, dict) or not changes:
        raise ValueError("바꿀 값이 없습니다")
    clean = {}
    for key, value in changes.items():
        if key == "aliases":
            clean[key] = validate_aliases(value, cfg)
            continue
        if key == "wake_words":
            clean[key] = None if value is None else validate_wake(value, cfg)
            continue
        if key == "macros":
            clean[key] = validate_macros(value, cfg)
            continue
        field = FIELDS.get(key)
        if not field:
            raise ValueError("화면에서 바꿀 수 없는 설정입니다: %s" % key)
        if value is None:
            clean[key] = None
        elif field.get("type") == "bool":
            if not isinstance(value, bool):
                raise ValueError("%s: 켬·끔 값이 아닙니다" % field["label"])
            clean[key] = value
        else:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError("%s: 숫자가 아닙니다" % field["label"])
            if not field["min"] <= value <= field["max"]:
                raise ValueError("%s: %s~%s 사이로 정해 주세요" % (field["label"], field["min"], field["max"]))
            value = round(float(value), 2)
            if field.get("percent"):
                clean[key] = round(value / 100.0, 2)
            elif key == "mic_threshold":
                clean[key] = "%g%%" % value
            elif float(field["step"]).is_integer():
                clean[key] = int(round(value))
            else:
                clean[key] = value
    return clean


def validate_wake(value, cfg):
    """호출어. 첫 번째가 대표 이름(받아쓰기 힌트에도 들어간다), 나머지는 잘못 받아써질 때의 변형."""
    from router import squash
    if not isinstance(value, list) or not 1 <= len(value) <= 40:
        raise ValueError("호출어를 하나 이상 정하세요")
    phrases = {squash(p) for ps in cfg["commands"].values() for p in ps}
    clean = []
    for word in value:
        if not isinstance(word, str):
            raise ValueError("호출어가 글자가 아닙니다")
        word = " ".join(word.split())
        key = squash(word)
        if not key:
            continue
        if len(key) < 3:
            raise ValueError("호출어 ‘%s’: 세 글자 이상이어야 합니다. 짧으면 일상 대화에서 잘못 불립니다" % word)
        if len(key) > 20:
            raise ValueError("호출어 ‘%s’: 너무 깁니다" % word)
        if key in phrases or key.isdigit():
            raise ValueError("호출어 ‘%s’: 명령 말이나 숫자와 겹칩니다" % word)
        if word not in clean:
            clean.append(word)
    if not clean:
        raise ValueError("호출어를 하나 이상 정하세요")
    return clean


def validate_macros(value, cfg):
    """단축 명령: 말 → 보낼 프롬프트."""
    from router import squash
    if not isinstance(value, dict) or len(value) > 30:
        raise ValueError("단축 명령은 30개까지입니다")
    phrases = {squash(p) for ps in cfg["commands"].values() for p in ps}
    clean = {}
    for say, prompt in value.items():
        if not isinstance(say, str) or not 2 <= len(squash(say)) <= 20:
            raise ValueError("단축 명령의 부를 말은 두 글자 이상 스무 글자 이하로 정합니다")
        if squash(say) in phrases:
            raise ValueError("단축 명령 ‘%s’: 이미 있는 명령 말과 겹칩니다" % say)
        if re.match(r"\d+\s*번", say.strip()):
            raise ValueError("단축 명령 ‘%s’: 번호 고르기와 헷갈립니다" % say)
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 1000:
            raise ValueError("단축 명령 ‘%s’: 보낼 프롬프트를 적으세요(천 자까지)" % say)
        clean[" ".join(say.split())] = prompt.strip()
    return clean


def wake_suggestions(cfg, count=400):
    """호출어 없이 무시된 말 중 호출어와 비슷하게 받아써진 앞머리. 변형으로 넣으면 다음부터 알아듣는다."""
    from difflib import SequenceMatcher
    from router import squash
    main = cfg["wake_words"][0]
    target, words = squash(main), len(main.split())
    known = {squash(w) for w in cfg["wake_words"]}
    try:
        with open(common.LOG_PATH, encoding="utf-8") as f:
            lines = f.readlines()[-count:]
    except OSError:
        return []
    seen = {}
    for line in lines:
        m = re.search(r" ignore ← (.*?)… \(\d+자\)$", line.rstrip("\n"))
        if not m:
            continue
        head = " ".join(re.sub(r"[\.,!\?~\"'“”]", " ", m.group(1)).split()[:words]).strip("- ")
        key = squash(head)
        # 호출어의 일부만 들린 것("클로드")은 넣으면 일상 대화에서 불리므로 추천하지 않는다.
        if not key or key in known or len(key) < max(3, len(target) - 1):
            continue
        if SequenceMatcher(None, key, target).ratio() >= 0.6:
            seen[head] = seen.get(head, 0) + 1
    return [{"text": text, "count": n} for text, n in sorted(seen.items(), key=lambda x: -x[1])[:6]]


def validate_aliases(value, cfg):
    from router import squash
    if not isinstance(value, dict) or len(value) > 20:
        raise ValueError("별명은 20개까지입니다")
    phrases = {squash(p) for ps in cfg["commands"].values() for p in ps}
    clean = {}
    for alias, target in value.items():
        if not isinstance(alias, str) or not 1 <= len(squash(alias)) <= 12:
            raise ValueError("별명은 한 글자 이상 열두 글자 이하로 정합니다")
        if squash(alias) in phrases or re.fullmatch(r"\d+번?", squash(alias)):
            raise ValueError("별명 ‘%s’: 명령 말이나 번호와 겹칩니다" % alias)
        if isinstance(target, bool) or not isinstance(target, (str, int)) or not str(target).strip() \
                or len(str(target)) > 60:
            raise ValueError("별명 ‘%s’: 가리킬 세션을 고르세요" % alias)
        clean[alias.strip()] = target.strip() if isinstance(target, str) else target
    return clean


def snapshot(mem):
    cfg = common.load_config()
    paused = common.paused_until()
    pending = mem.get("pending")
    if pending and time.time() > pending["expires"]:
        pending = None
    armed_left = max(0.0, mem.get("armed_until", 0) - time.time())
    dictation = mem.get("dictation")
    latency = mem.get("latency", [])
    return {
        "phase": "paused" if paused else mem.get("phase", "idle"),
        "paused_until": 0 if paused >= common.FOREVER else paused,
        "armed_left": round(armed_left, 1),
        "pending": (pending.get("text") or "창에 답하기") if pending else "",
        "speaking": common.is_speaking(),
        "dictation": {"where": dictation["where"], "text": " ".join(dictation["parts"]),
                      "idle": round(time.time() - dictation["last"]),
                      "limit": cfg.get("dictation_idle_sec", 30)} if dictation else None,
        "latency": latency[-1] if latency else None,
        "latency_avg": round(sum(x["wait"] + x["write"] + x["act"] for x in latency) / len(latency), 1) if latency else None,
        "aliases": cfg.get("aliases", {}),
        "wake": cfg["wake_words"][0],
        "tts": bool(cfg.get("tts")),
        "confirm": bool(cfg.get("confirm_before_send")),
        "threshold": float(str(cfg["mic_threshold"]).rstrip("%")) / 100.0,
        "sessions": watch["sessions"],
        "events": recent_events(),
        "groups": [{"title": title, "rows": [{"name": name, "phrases": cfg["commands"].get(key, [])}
                                             for key, name in rows]} for title, rows in GROUPS],
        "patterns": [{"say": say, "does": does} for say, does in PATTERNS],
        "macros": [{"say": say, "does": does} for say, does in cfg.get("macros", {}).items()],
        "now": time.time(),
    }


def serve(cfg, mem):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/state":
                watch["seen"] = time.time()
                self.reply(json.dumps(snapshot(mem), ensure_ascii=False).encode("utf-8"), "application/json")
            elif self.path == "/level":
                # 음량 막대는 자주 묻는다. 가볍게 숫자 둘만 준다.
                body = json.dumps({"level": round(mem.get("level", 0.0), 4), "phase": mem.get("phase", "idle")})
                self.reply(body.encode("utf-8"), "application/json")
            elif self.path == "/config":
                self.reply(json.dumps(settings_view(), ensure_ascii=False).encode("utf-8"), "application/json")
            elif self.path in ("/", "/index.html"):
                with open(PAGE, "rb") as f:
                    self.reply(f.read(), "text/html")
            else:
                self.send_error(404)

        def do_POST(self):
            # 다른 웹 페이지가 이 주소로 설정을 바꾸지 못하게: 같은 출처, JSON, 우리만 붙이는 헤더를 요구한다.
            origin = self.headers.get("Origin", "")
            allowed = ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)
            if self.path != "/config" or (origin and origin not in allowed) \
                    or self.headers.get("X-Handsfree") != "1" \
                    or not self.headers.get("Content-Type", "").startswith("application/json"):
                self.send_error(403)
                return
            try:
                length = min(int(self.headers.get("Content-Length", "0")), 20000)
                changes = validate(json.loads(self.rfile.read(length).decode("utf-8")), common.load_config())
            except ValueError as exc:
                self.reply(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False).encode("utf-8"),
                           "application/json", status=400)
                return
            if not common.update_user_config(changes):
                self.reply(json.dumps({"ok": False, "error": "설정 파일이 깨져 있어 저장하지 못했습니다"},
                                      ensure_ascii=False).encode("utf-8"), "application/json", status=409)
                return
            common.log("설정 변경: " + ", ".join(sorted(changes)))
            self.reply(json.dumps({"ok": True, **settings_view()}, ensure_ascii=False).encode("utf-8"),
                       "application/json")

        def reply(self, body, kind, status=200):
            self.send_response(status)
            self.send_header("Content-Type", kind + "; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    port = int(cfg.get("ui_port", 8179))
    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError as exc:
        common.log("상태 화면을 띄우지 못함: %r" % exc)
        return
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(target=refresh_sessions, daemon=True).start()
