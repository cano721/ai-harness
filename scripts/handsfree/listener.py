#!/usr/bin/env python3
"""마이크 → 받아쓰기 → 분류 → Orca 세션. `handsfree start` 가 백그라운드로 띄운다."""
import array
import collections
import json
import math
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai  # noqa: E402
import common  # noqa: E402
import orca  # noqa: E402
import reading  # noqa: E402
import ui  # noqa: E402
from router import has_wake, route, said, squash, strip_wake  # noqa: E402

WAV = os.path.join(common.HOME_DIR, "utterance.wav")
# 호출어를 같은 말 안에서 부르지 않았으면(대기 중에 들어온 말) 받지 않는 동작.
NEEDS_WAKE = ("approve", "approve_force", "choose", "enter")
YES_OPTION = re.compile(r"^1\.\s*(yes|예|네)\b", re.I)
children = []
mem = {"armed_until": 0, "pending": None, "config_warned": False, "screens": {}, "phase": "idle", "level": 0.0,
       "dictation": None, "latency": [], "acted": False}
lock = threading.RLock()  # 듣기 흐름과 긴 말 모드 시간 감시가 같은 상태를 만진다


# ── 듣기 ──────────────────────────────────────────────

def start_whisper(cfg):
    model = os.path.join(common.MODEL_DIR, cfg["model"])
    if not os.path.exists(model):
        raise SystemExit("모델 없음: %s (handsfree setup 실행)" % model)
    binary = common.whisper_binary()
    if not binary:
        raise SystemExit("whisper-server 없음 (handsfree setup 실행)")
    log = open(os.path.join(common.HOME_DIR, "whisper.log"), "w")
    proc = subprocess.Popen(
        [binary, "-m", model, "-l", cfg["language"], "--host", "127.0.0.1", "--port", str(cfg["port"])],
        stdout=log, stderr=log,
    )
    children.append(proc)
    for _ in range(120):
        if proc.poll() is not None:
            raise SystemExit("whisper-server 가 바로 종료됨. whisper.log 확인")
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/" % cfg["port"], timeout=1)
            return
        except Exception:
            time.sleep(0.5)
    raise SystemExit("whisper-server 준비 시간 초과")


class Mic:
    """마이크를 계속 읽어 둔다. 처리하느라 바쁜 동안 한 말도 놓치지 않는다."""
    FRAME = 960  # 16kHz 16비트 30ms

    def __init__(self):
        self.frames = queue.Queue()
        self.proc = subprocess.Popen(
            ["rec", "-q", "-c", "1", "-r", "16000", "-b", "16", "-e", "signed-integer", "-t", "raw", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        children.append(self.proc)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            data = self.proc.stdout.read(self.FRAME)
            if len(data) < self.FRAME:
                self.frames.put(None)
                return
            self.frames.put((time.time(), data))

    def next_frame(self):
        frame = self.frames.get()
        if frame is None:
            self.frames.put(None)  # 끊겼다는 신호를 남겨 둬야 다음 호출도 기다리지 않고 바로 실패한다
            raise RuntimeError("마이크 입력이 끊겼습니다")
        return frame


def loudness(data):
    """프레임 음량을 최대치 대비 비율(0~1)로."""
    samples = array.array("h", data)
    return math.sqrt(sum(x * x for x in samples) / float(len(samples))) / 32768.0


def cut_utterance(next_frame, cfg):
    """말 한 덩어리를 잘라 (소리, 길이 초, 시작 시각, 잘림 여부)로 돌려준다.

    말 첫머리의 약한 소리("헤")가 기준에 못 미쳐 잘리지 않게 시작 직전 소리를 앞에 붙인다.
    """
    threshold = float(str(cfg["mic_threshold"]).rstrip("%")) / 100.0
    before = collections.deque(maxlen=int(float(cfg.get("pre_roll_sec", 0.5)) / 0.03))
    recent = collections.deque(maxlen=5)
    while True:
        stamp, data = next_frame()
        before.append((stamp, data))
        level = loudness(data)
        mem["level"] = level
        recent.append(level >= threshold)
        if sum(recent) >= 3:
            break
    mem["phase"] = "hearing"
    started_at = before[0][0]
    chunks = [data for _, data in before]
    quiet, quiet_limit = 0, int(float(cfg["silence_sec"]) / 0.03)
    limit = int(float(cfg["max_utterance_sec"]) / 0.03)
    while quiet < quiet_limit and len(chunks) < limit:
        _, data = next_frame()
        chunks.append(data)
        level = loudness(data)
        mem["level"] = level
        quiet = quiet + 1 if level < threshold * 0.7 else 0
    return b"".join(chunks), len(chunks) * 0.03, started_at, len(chunks) >= limit


def save_wav(path, sound):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(sound)


def transcribe(path, cfg):
    boundary = uuid.uuid4().hex
    fields = {
        "response_format": "json",
        "language": cfg["language"],
        "temperature": "0",
        # 호출어를 앞에 넣어 줘야 짧게 부른 말을 "감사합니다" 같은 엉뚱한 문장으로 받아쓰지 않는다.
        "prompt": ", ".join(cfg["wake_words"][:1] + cfg.get("vocabulary", [])),
    }
    body = b""
    for name, value in fields.items():
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, name, value)).encode()
    with open(path, "rb") as f:
        body += ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.wav\"\r\n"
                 "Content-Type: audio/wav\r\n\r\n" % boundary).encode() + f.read() + b"\r\n"
    body += ("--%s--\r\n" % boundary).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:%d/inference" % cfg["port"], data=body,
        headers={"Content-Type": "multipart/form-data; boundary=" + boundary},
    )
    with urllib.request.urlopen(req, timeout=120) as res:
        return " ".join(json.loads(res.read().decode("utf-8")).get("text", "").split())


def keep_sample(text, cfg):
    """인식이 안 될 때 원인을 보려고 최근 녹음 몇 개만 남긴다. debug_samples 가 0 이면 남기지 않는다."""
    count = int(cfg.get("debug_samples", 0))
    folder = os.path.join(common.HOME_DIR, "samples")
    if count <= 0:
        return
    os.makedirs(folder, exist_ok=True)
    name = time.strftime("%H%M%S")
    shutil.copy(WAV, os.path.join(folder, name + ".wav"))
    with open(os.path.join(folder, name + ".txt"), "w", encoding="utf-8") as f:
        f.write(text)
    for old in sorted(os.listdir(folder))[:-count * 2]:
        os.remove(os.path.join(folder, old))


# ── 알리기 ────────────────────────────────────────────

def tell(message, cfg, speak="tts", sound="Tink", refused=False):
    """speak: always 는 설정과 무관하게 소리로, tts 는 읽어 주기가 켜져 있을 때만, never 는 알림만."""
    # 기록의 앞머리로 한 일(→)과 하지 않은 일(✕)을 가른다. 상태 화면이 이걸로 색을 나눈다.
    common.log(("✕ " if refused else "→ ") + message)
    common.beep(sound)
    common.notify("handsfree", message)
    if speak == "always" or (speak == "tts" and cfg.get("tts")):
        common.say(reading.clean(message, cfg["wake_words"]), cfg)


def refuse(message, cfg):
    """하지 않은 일은 화면을 못 봐도 알 수 있게 항상 소리로 알린다."""
    tell(message, cfg, speak="always", sound="Basso", refused=True)


# ── 세션 ──────────────────────────────────────────────

def snapshot():
    """세션 목록과 현재 세션 화면을 동시에 읽는다. 하나씩 읽으면 그만큼 반응이 늦는다."""
    handle = common.load_state().get("current")
    with ThreadPoolExecutor(max_workers=2) as pool:
        listing = pool.submit(orca.sessions)
        shot = pool.submit(orca.screen, handle) if handle else None
        mem["screens"] = {handle: shot.result()} if shot else {}
        items = listing.result()
    follow_focus(items)
    return items


def follow_focus(items):
    """Orca 에서 클릭해 앞에 띄운 탭을 입력 대상으로 삼는다.
    앞 탭이 바뀐 순간에만 따라간다. 늘 맞추면 키보드로 친 세션이나 "N번 세션"으로 정한 대상을 다음 말에 덮어쓴다."""
    active = next((s for s in items if s.get("active")), None)
    if not active:
        return
    state = common.load_state()
    if state.get("seen_active") == active["handle"]:
        return
    common.update_state(seen_active=active["handle"])
    if common.load_config().get("follow_focus", True) and state.get("current") != active["handle"]:
        common.update_state(current=active["handle"])
        common.log("→ 화면에서 고른 세션을 음성 입력 대상으로 바꿈: %s" % orca.label(active))


def screen_of(handle):
    """미리 읽어 둔 화면은 한 번만 쓴다. 두 번째부터는 새로 읽어야 그사이 뜬 창을 본다."""
    if handle in mem.get("screens", {}):
        return mem["screens"].pop(handle)
    return orca.screen(handle)


def current_session(items):
    handle = common.load_state().get("current")
    for i, s in enumerate(items):
        if s["handle"] == handle:
            return i, s
    return None, None


def by_alias(alias, items, cfg):
    """별명이 가리키는 세션. 값은 탭 이름(일부)이나 번호."""
    target = cfg.get("aliases", {}).get(alias)
    if isinstance(target, int) or (isinstance(target, str) and target.isdigit()):
        index = int(target)
        return items[index - 1] if 1 <= index <= len(items) else None
    return orca.find_by_name(str(target or ""), items)


def number_of(session, items):
    return items.index(session) + 1


def goto(items, index, cfg):
    target = items[index]
    common.update_state(current=target["handle"])
    shown = orca.switch(target["handle"])
    tell("%d번 %s%s" % (index + 1, orca.label(target), "" if shown else " (화면 전환은 실패)"), cfg)


def waiting_sessions(items):
    """승인 창이 떠 있는 세션 번호들."""
    with ThreadPoolExecutor(max_workers=8) as pool:
        screens = list(pool.map(lambda s: orca.screen(s["handle"]), items))
    return [i + 1 for i, text in enumerate(screens) if orca.dialog(text)], screens


def is_danger(dlg, session, cfg):
    record = common.read_json(common.session_file(session["handle"]), {})
    text = dlg["full"].lower()
    return bool(record.get("danger")) or any(p.lower() in text for p in cfg.get("danger_patterns", []))


def is_broad(option_text, cfg):
    text = option_text.lower()
    return any(p.lower() in text for p in cfg.get("broad_option_patterns", []))


def send_prompt(session, items, text, cfg):
    """승인 창이 떠 있거나 화면을 못 읽으면 보내지 않는다. 글자와 엔터가 창의 키 입력으로 먹기 때문이다."""
    where = "%d번 %s" % (number_of(session, items), orca.label(session))
    scr = screen_of(session["handle"])
    if scr is None:
        refuse("%s 화면을 읽지 못해 보내지 않았습니다" % where, cfg)
        return
    if orca.dialog(scr):
        refuse("%s 세션에 승인 창이 떠 있어 보내지 않았습니다. ‘승인’, ‘거절’이나 번호로 답해 주세요" % where, cfg)
        return
    if not orca.input_ready(scr):
        refuse("%s 화면에서 입력 칸을 찾지 못해 보내지 않았습니다" % where, cfg)
        return
    if orca.send(session["handle"], text, enter=True):
        common.update_state(last_sent={"handle": session["handle"], "text": text, "at": time.time()})
        tell("%s에 보냈습니다. %s" % (where, text), cfg)
    else:
        refuse("%s 전송에 실패했습니다" % where, cfg)


def answer_dialog(session, items, action, cfg, dlg):
    """승인 창에 답한다. 넓은 권한을 주는 선택지와 위험 명령은 한 단어로 통과시키지 않는다."""
    kind = action["type"]
    where = "%d번 %s" % (number_of(session, items), orca.label(session))
    options = dlg["options"]

    if kind == "deny":
        orca.send(session["handle"], "\x1b")
        common.update_session(session["handle"], pending="", danger=False)
        tell("%s: 거절했습니다" % where, cfg, sound="Funk")
        return

    if kind in ("approve", "approve_force"):
        if dlg["selected"] != 1 or not YES_OPTION.match(options.get(1, "")) or is_broad(options.get(1, ""), cfg):
            refuse("이 창은 승인 대신 번호로 골라 주세요. " + " / ".join(options.values()), cfg)
            return
        number = 1
    else:
        number = action["number"]
        if number > 9:
            refuse("10번 이상은 음성으로 고를 수 없습니다", cfg)
            return
        if number not in options:
            refuse("%d번 선택지가 없습니다" % number, cfg)
            return
        if is_broad(options[number], cfg):
            refuse("%d번은 앞으로 묻지 않고 허용하는 선택지라 음성으로는 고를 수 없습니다" % number, cfg)
            return

    accepts = YES_OPTION.match(options.get(number, "")) or re.match(r"^\d+\.\s*yes\b", options.get(number, ""), re.I)
    if accepts and kind != "approve_force" and is_danger(dlg, session, cfg):
        refuse("위험할 수 있는 명령입니다. %s. 실행하려면 ‘확실히 승인’이라고 말해 주세요" % dlg["text"][:200], cfg)
        return
    if action.get("from_ai") and not action.get("confirmed"):
        mem["pending"] = {"kind": "dialog", "handle": session["handle"], "action": dict(action, confirmed=True),
                          "expires": wait_until(options[number], cfg)}
        tell("%s. 이걸로 고를까요?" % options[number], cfg, speak="always", sound="Pop")
        return

    if not orca.send(session["handle"], "\r" if kind != "choose" else str(number)):
        refuse("%s 전송에 실패했습니다" % where, cfg)
        return
    common.update_session(session["handle"], pending="", danger=False)
    tell("%s: %s" % (where, "승인했습니다" if kind != "choose" else "%d번을 골랐습니다" % number), cfg, sound="Hero")


def read_answer(session, mode, cfg):
    data = common.read_json(common.session_file(session["handle"]), {})
    text = data.get("last", "")
    if not text:
        refuse("읽을 답변이 없습니다", cfg)
        return
    start = data.get("offset", 0) if mode == "read_more" else 0
    if start >= len(text):
        refuse("끝까지 읽었습니다", cfg)
        return
    limit = 3000 if mode == "read_all" else int(cfg.get("tts_max_chars", 220))
    piece, offset = reading.chunk(text, start, limit)
    common.update_session(session["handle"], offset=offset)
    common.say(piece, cfg)


def explain_dialog(session, cfg):
    dlg = orca.dialog(screen_of(session["handle"]))
    if not dlg:
        refuse("승인 창이 없습니다", cfg)
        return
    summary = common.read_json(common.session_file(session["handle"]), {}).get("pending", "")
    text = (summary + ". " if summary else "") + dlg["text"]
    common.log("→ 승인 내용: " + text)
    common.say(reading.clean(text, cfg["wake_words"]), cfg)


def status_all(items, cfg, quiet_if_idle=False):
    _, screens = waiting_sessions(items)
    states = [(i + 1, orca.state_of(text)) for i, text in enumerate(screens)]
    parts = []
    for label in ("승인 대기", "작업 중", "확인 불가"):
        numbers = ["%d번" % n for n, state in states if state == label]
        if numbers:
            parts.append("%s %s" % (", ".join(numbers), label))
    if parts or not quiet_if_idle:
        tell(". ".join(parts) if parts else "모두 대기 중입니다", cfg, speak="always")


# ── 동작 실행 ─────────────────────────────────────────

def save_setting(key, value, cfg):
    if common.set_user_config(key, value):
        cfg[key] = value
        return True
    refuse("설정 파일이 깨져 있어 저장하지 못했습니다", cfg)
    return False


def execute(action, cfg):
    kind = action["type"]
    if kind == "stop_speaking":
        common.stop_speaking()
    elif kind in ("tts_on", "tts_off"):
        on = kind == "tts_on"
        if not on:
            common.stop_speaking()
        if save_setting("tts", on, cfg):
            tell("답변 자동 읽기를 %s" % ("켰습니다" if on else "껐습니다"), cfg, speak="always" if on else "never")
    elif kind in ("confirm_on", "confirm_off"):
        on = kind == "confirm_on"
        if save_setting("confirm_before_send", on, cfg):
            tell("보내기 전 확인을 %s" % ("켰습니다" if on else "껐습니다"), cfg, speak="always")
    elif kind == "pause":
        minutes = action.get("minutes")
        if minutes is not None and minutes < 1:
            refuse("몇 분 쉴지 다시 말해 주세요", cfg)
            return
        common.set_paused(time.time() + minutes * 60 if minutes else common.FOREVER)
        tell("%s 쉽니다. ‘다시 켜’라고 하면 돌아옵니다" % ("%d분" % minutes if minutes else "잠시"), cfg,
             speak="always", sound="Bottle")
    elif kind == "open_ui":
        url = "http://127.0.0.1:%d/" % int(cfg.get("ui_port", 8179))
        opened = subprocess.run([orca.ORCA, "tab", "create", "--url", url], capture_output=True).returncode == 0
        if not opened:
            opened = subprocess.run(["open", url]).returncode == 0
        tell("상태 화면을 열었습니다" if opened else "상태 화면을 열지 못했습니다", cfg,
             sound="Tink" if opened else "Basso")
    elif kind == "resume":
        common.set_paused(0)
        tell("다시 듣습니다", cfg, speak="always", sound="Glass")
        status_all(orca.sessions(), cfg, quiet_if_idle=True)
    else:
        execute_in_session(action, cfg)


def execute_in_session(action, cfg):
    kind = action["type"]
    items = snapshot()
    index, session = current_session(items)

    if kind == "ping":
        state = "쉬는 중입니다" if common.paused_until() else "듣고 있습니다"
        here = "지금은 %d번 %s에 입력합니다" % (index + 1, orca.label(session)) if session else "입력할 세션이 정해지지 않았습니다"
        tell("%s. %s" % (state, here), cfg, speak="always")
        return
    if kind == "list_sessions":
        tell(", ".join("%d번 %s" % (i + 1, orca.label(s)) for i, s in enumerate(items)), cfg, speak="always")
        return
    if kind == "status_all":
        status_all(items, cfg)
        return
    if kind == "goto_session":
        if 1 <= action["index"] <= len(items):
            goto(items, action["index"] - 1, cfg)
        else:
            refuse("%d번 세션은 없습니다. 세션은 %d개입니다" % (action["index"], len(items)), cfg)
        return
    if kind in ("next_session", "prev_session"):
        if index is None:
            refuse("현재 세션을 찾지 못했습니다. 몇 번 세션인지 말해 주세요", cfg)
            return
        goto(items, (index + (1 if kind == "next_session" else -1)) % len(items), cfg)
        return
    if kind == "goto_session_named":
        target = by_alias(action["alias"], items, cfg) if action.get("alias") else orca.find_by_name(action["name"], items)
        if action.get("alias") and not target:
            refuse("별명 ‘%s’에 맞는 세션을 찾지 못했습니다" % action["alias"], cfg)
            return
        if target:
            goto(items, items.index(target), cfg)
            return
        action = dict(action, type="prompt", text=action["spoken"])
        kind = "prompt"
    if kind == "undo":
        last = common.load_state().get("last_sent")
        if not last or time.time() - last["at"] > 180:
            refuse("방금 보낸 말이 없습니다", cfg)
            return
        orca.send(last["handle"], "\x1b")
        tell("방금 보낸 작업을 멈췄습니다. 이미 실행된 것은 되돌려지지 않습니다. 보낸 말은 " + last["text"], cfg, speak="always")
        return

    # 번호나 이름으로 다른 세션을 가리킨 경우
    if "index" in action:
        if not 1 <= action["index"] <= len(items):
            refuse("%d번 세션이 없습니다" % action["index"], cfg)
            return
        session, targeted = items[action["index"] - 1], True
    elif action.get("alias"):
        session = by_alias(action["alias"], items, cfg)
        if session is None:
            refuse("별명 ‘%s’에 맞는 세션을 찾지 못했습니다" % action["alias"], cfg)
            return
        targeted = True
    elif action.get("session_name"):
        target = orca.find_by_name(action["session_name"], items)
        if not target and kind == "notify_done":
            # "빌드 끝나면 알려 줘"처럼 세션 이름이 아닌 말이면 세션에게 하는 부탁이다.
            action, kind = {"type": "prompt", "text": action["spoken"]}, "prompt"
        if target:
            session, targeted = target, True
        else:
            action = dict(action, text=action.get("spoken") or action.get("text", ""))
            targeted = False
    else:
        targeted = False
    if session is None:
        refuse("현재 세션을 찾지 못했습니다. 몇 번 세션인지 먼저 말해 주세요", cfg)
        return
    where = "%d번 %s" % (number_of(session, items), orca.label(session))

    if kind == "notify_done":
        state = orca.state_of(screen_of(session["handle"]))
        if state == "대기":
            tell("%s: 지금 하는 일이 없습니다" % where, cfg, speak="always")
            return
        common.update_session(session["handle"], notify_done=True)
        tell("%s: 끝나거나 승인이 필요하면 알려 드리겠습니다" % where, cfg, speak="always")
        return
    if kind == "dictate":
        with lock:
            mem["dictation"] = {"handle": session["handle"], "where": where, "parts": [], "last": time.time()}
        tell("%s에 보낼 말을 길게 받아씁니다. 다 말했으면 ‘보내’, 버리려면 ‘취소’라고 하세요" % where, cfg, speak="always", sound="Glass")
    elif kind == "current_session":
        tell(where, cfg, speak="always")
    elif kind == "interrupt":
        orca.send(session["handle"], "\x1b")
        tell("%s: 멈췄습니다" % where, cfg, sound="Funk")
    elif kind == "enter":
        scr = screen_of(session["handle"])
        if scr is None or orca.dialog(scr) or not orca.input_ready(scr):
            refuse("입력 칸이 보이지 않아 엔터를 누르지 않았습니다. 승인 창이면 ‘승인’이라고 말해 주세요", cfg)
        else:
            orca.send(session["handle"], "\r")
            tell("%s: 엔터를 눌렀습니다" % where, cfg)
    elif kind in ("read_last", "read_more", "read_all"):
        read_answer(session, kind, cfg)
    elif kind == "read_summary":
        if not common.read_json(common.session_file(session["handle"]), {}).get("last"):
            refuse("읽을 답변이 없습니다", cfg)
        else:
            # 요약은 몇 초 걸린다. 듣기를 붙잡지 않게 따로 띄우고, 다 되면 그쪽에서 읽는다.
            subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "speak.py"),
                              "--summarize", session["handle"]],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            tell("%s 답변을 요약하고 있습니다" % where, cfg, speak="never", sound="Pop")
    elif kind == "explain_dialog":
        explain_dialog(session, cfg)
    elif kind in ("approve", "approve_force", "deny", "choose"):
        respond(session, items, action, cfg, targeted)
    elif kind == "prompt":
        if action.get("macro") or action.get("literal") or targeted:
            deliver(session, items, action, cfg)
        else:
            interpret(session, items, action, cfg)


def respond(session, items, action, cfg, targeted):
    """승인·거절·번호. 창이 있으면 창에 답하고, 어디에도 창이 없으면 한 말 그대로가 질문에 대한 답이다."""
    where = "%d번 %s" % (number_of(session, items), orca.label(session))
    scr = screen_of(session["handle"])
    if scr is None:
        refuse("%s 화면을 읽지 못했습니다. 다시 말해 주세요" % where, cfg)
        return
    dlg = orca.dialog(scr)
    if dlg:
        answer_dialog(session, items, action, cfg, dlg)
        return
    if targeted or action["type"] == "approve_force":
        refuse("%s 세션에 승인 창이 없습니다" % where, cfg)
        return
    waiting, _ = waiting_sessions(items)
    if waiting:
        numbers = ", ".join("%d번" % n for n in waiting)
        refuse("승인 창은 %s 세션에 있습니다. ‘%d번 세션 승인’처럼 말해 주세요"
               % (numbers, waiting[0]), cfg)
        return
    deliver(session, items, {"type": "prompt", "text": action.get("spoken", ""), "literal": True,
                             "armed": action.get("armed")}, cfg)


def interpret(session, items, action, cfg):
    """표에 없는 말. 승인 창이 떠 있으면 글자를 보낼 수 없으니 창에 대한 답인지 뜻을 판단한다."""
    scr = screen_of(session["handle"])
    dlg = orca.dialog(scr) if scr is not None else None
    if scr is None or not dlg:
        deliver(session, items, action, cfg)
        return
    guess = None
    if cfg.get("ai_fallback"):
        common.beep("Pop")
        guess = ai.classify(action["text"], dlg, cfg)
        common.log("ai %s" % json.dumps(guess, ensure_ascii=False))
    if guess and guess["type"] == "explain_dialog":
        explain_dialog(session, cfg)
    elif guess and guess["type"] in ("approve", "deny", "choose"):
        answer_dialog(session, items, dict(guess, from_ai=True), cfg, dlg)
    else:
        refuse("승인 창이 떠 있어 보내지 않았습니다. ‘승인’, ‘거절’이나 번호로 답해 주세요", cfg)


def wait_until(text, cfg):
    """되묻는 말을 다 읽을 시간을 더해 대답을 기다린다."""
    return time.time() + int(cfg.get("confirm_window_sec", 20)) + len(text) / 5.0


def deliver(session, items, action, cfg):
    """프롬프트 전송. 확인 모드이거나 이름으로 세션을 가리켰으면 읽어 주고 대답을 기다린다."""
    ask = cfg.get("confirm_before_send") or action.get("ask_first")
    if ask and not action.get("confirmed"):
        mem["pending"] = {"kind": "prompt", "handle": session["handle"], "text": action["text"],
                          "expires": wait_until(action["text"], cfg)}
        tell("%s. %d번 세션에 보낼까요?" % (action["text"], number_of(session, items)), cfg,
             speak="always", sound="Pop")
        return
    send_prompt(session, items, action["text"], cfg)


def answer_pending(rest, cfg):
    """확인 대기 중인 것에 대한 대답이면 처리하고 True."""
    pending = mem["pending"]
    if not pending:
        return False
    yes, no = said(rest, cfg.get("confirm_yes", [])), said(rest, cfg.get("confirm_no", []))
    if time.time() > pending["expires"]:
        mem["pending"] = None
        if yes or no:
            refuse("시간이 지나 보내지 않았습니다. 처음부터 다시 말해 주세요", cfg)
        return yes or no
    if yes:
        mem["pending"] = None
        items = orca.sessions()
        session = next((s for s in items if s["handle"] == pending["handle"]), None)
        if session is None:
            refuse("보낼 세션이 닫혔습니다", cfg)
        elif pending["kind"] == "prompt":
            send_prompt(session, items, pending["text"], cfg)
        else:
            dlg = orca.dialog(screen_of(session["handle"]))
            if dlg:
                answer_dialog(session, items, pending["action"], cfg, dlg)
            else:
                refuse("승인 창이 이미 닫혔습니다", cfg)
        return True
    if no:
        mem["pending"] = None
        tell("보내지 않았습니다", cfg, speak="always", sound="Funk")
        return True
    return False


def take_dictation(text, woke, rest, cfg):
    """긴 말 모드에서 들은 말. 끝내는 말이면 모아서 보내고, 아니면 쌓는다."""
    body = rest if woke else text.strip()
    with lock:
        dictation = mem["dictation"]
        if not dictation:
            return False
        if said(body, cfg.get("dictation_cancel", [])):
            mem["dictation"] = None
            common.log("dictation ← " + body)
            tell("받아쓴 말을 버렸습니다", cfg, speak="always", sound="Funk")
            return True
        if said(body, cfg.get("dictation_send", [])):
            mem["dictation"] = None
            common.log("dictation ← " + body)
            finish_dictation(dictation, cfg)
            return True
        if body:
            dictation["parts"].append(body)
            dictation["last"] = time.time()
            common.log("dictation ← " + body)
            common.beep("Morse")
    return True


def finish_dictation(dictation, cfg, ask=False):
    text = " ".join(dictation["parts"]).strip()
    if not text:
        refuse("받아쓴 말이 없습니다", cfg)
        return
    items = orca.sessions()
    session = next((s for s in items if s["handle"] == dictation["handle"]), None)
    if session is None:
        refuse("받아쓰던 세션이 닫혔습니다", cfg)
        return
    deliver(session, items, {"type": "prompt", "text": text, "ask_first": ask}, cfg)


def watch_dictation():
    """긴 말 모드에서 한동안 말이 없으면 그대로 두지 않고 보낼지 묻는다. 버리지는 않는다."""
    while True:
        time.sleep(1)
        cfg = common.load_config()
        with lock:
            dictation = mem["dictation"]
            if not dictation or time.time() - dictation["last"] < float(cfg.get("dictation_idle_sec", 30)):
                continue
            mem["dictation"] = None
            try:
                if dictation["parts"]:
                    finish_dictation(dictation, cfg, ask=True)
                else:
                    tell("들은 말이 없어 긴 말 모드를 끝냈습니다", cfg, speak="always", sound="Funk")
            except Exception as exc:
                common.log("오류: %r" % exc)


def handle_text(text, cfg, started_at=None, truncated=False):
    """받아쓴 문장 하나 처리."""
    started_at = started_at or time.time()
    wake_words = cfg["wake_words"]
    woke, rest = strip_wake(text, wake_words)
    speaking = common.is_speaking()

    if cfg.get("config_broken") and not mem["config_warned"]:
        mem["config_warned"] = True
        refuse("설정 파일을 읽지 못해 기본값으로 동작합니다", cfg)

    # 읽어 주는 소리와 겹쳐 들어온 말은 맨 앞에 호출어가 오지 않는다. 그때는 읽기만 멈춘다.
    if speaking and not woke and has_wake(text, wake_words):
        common.log("stop_speaking ← (읽는 중 호출)")
        common.stop_speaking()
        return

    if common.paused_until():
        if woke:
            action = route(text, cfg)
            common.log("%s ← %s (쉬는 중)" % (action["type"], rest[:20]))
            if action["type"] in ("resume", "ping"):
                execute(action, cfg)
            elif action["type"] != "wake_only":
                refuse("쉬는 중입니다. ‘다시 켜’라고 하면 돌아옵니다", cfg)
        return

    if mem["dictation"] and take_dictation(text, woke, rest, cfg):
        mem["acted"] = True
        return

    # 방금 되물은 것에 대한 대답은 호출어 없이도 받는다. 한 글자("응")는 주변 소리와 구분이 안 돼 호출어가 필요하다.
    if (woke or len(squash(rest)) >= 2) and answer_pending(rest, cfg):
        common.log("confirm ← " + rest)
        return

    armed = started_at < mem["armed_until"] and not common.spoke_since(started_at)
    action = route(text, cfg, armed=armed)
    if action["type"] == "ignore":
        # 호출어 없는 말은 집 안 대화다. 내용은 남기지 않고 호출어 오인식을 찾을 앞머리만 적는다.
        head = max(8, len(cfg["wake_words"][0]) + 3)
        common.log("ignore ← %s… (%d자)" % (text[:head], len(text)))
        return
    common.log("%s%s ← %s" % (action["type"], " (대기 중)" if action.get("armed") else "", text))
    mem["acted"] = True

    if truncated:
        refuse("말이 너무 길어 잘렸습니다. 보내지 않았습니다. 나눠 말하거나 ‘길게 말할게’로 시작해 주세요", cfg)
        return
    if action["type"] == "wake_only":
        mem["armed_until"] = time.time() + cfg["wake_window_sec"]
        common.beep("Pop")
        return
    mem["armed_until"] = 0
    common.beep("Pop")
    if action.get("armed") and action["type"] in NEEDS_WAKE:
        refuse("승인과 선택은 호출어와 함께 한 번에 말해 주세요", cfg)
        return
    if speaking and action["type"] == "interrupt":
        action = {"type": "stop_speaking"}
    execute(action, cfg)


def restart(cfg):
    """자식 프로세스(받아쓰기 서버, 녹음)를 모두 내리고 새로 띄운다."""
    for proc in list(children):
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            pass
    children.clear()
    start_whisper(cfg)
    return Mic()


def shutdown(*_):
    for proc in list(children):
        try:
            proc.terminate()
        except OSError:
            pass
    common.set_paused(0)
    try:
        os.remove(common.PID_PATH)
    except OSError:
        pass
    sys.exit(0)


def main():
    os.makedirs(common.HOME_DIR, exist_ok=True)
    cfg = common.load_config()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    if len(sys.argv) > 2 and sys.argv[1] == "--file":
        # 검증용: 녹음 파일을 마이크 대신 넣어 받아쓰기와 분류만 본다. 세션에는 아무것도 보내지 않는다.
        start_whisper(cfg)
        try:
            for path in [p for p in sys.argv[2:] if p != "--dry"]:
                started = time.time()
                text = transcribe(path, cfg)
                print(json.dumps({"file": os.path.basename(path), "sec": round(time.time() - started, 2),
                                  "text": text, "action": route(text, cfg)}, ensure_ascii=False))
        finally:
            for proc in children:
                proc.terminate()
        return

    with open(common.PID_PATH, "w") as f:
        f.write(str(os.getpid()))
    common.set_paused(0)
    try:
        start_whisper(cfg)
    except SystemExit as exc:
        common.log("시작 실패: %s" % exc)
        shutdown()
    common.log("듣기 시작")
    common.beep("Glass")
    failures, recoveries = 0, []
    mic = Mic()
    ui.serve(cfg, mem)
    threading.Thread(target=watch_dictation, daemon=True).start()
    while True:
        try:
            mem["phase"] = "idle"
            cfg = common.load_config()
            sound, seconds, started_at, truncated = cut_utterance(mic.next_frame, cfg)
            # 말소리 없이 탁 하는 소리만 잡힌 짧은 구간은 받아쓰면 엉뚱한 문장이 나온다.
            if seconds < float(cfg.get("pre_roll_sec", 0.5)) + float(cfg["silence_sec"]) + 0.25:
                continue
            save_wav(WAV, sound)
            mem["phase"] = "transcribing"
            heard_at = time.time()
            text = transcribe(WAV, cfg)
            written_at = time.time()
            failures = 0
            keep_sample(text, cfg)
            if not text:
                continue
            cfg = common.load_config()
            mem["phase"] = "acting"
            with lock:
                mem["acted"] = False
                handle_text(text, cfg, started_at, truncated=truncated)
            # 무시된 말은 빼고, 실제로 무언가 한 말의 지연만 남긴다(말 끝 기다림 + 받아쓰기 + 처리).
            if mem["acted"]:
                mem["latency"] = (mem["latency"] + [{
                    "wait": float(cfg["silence_sec"]), "write": round(written_at - heard_at, 2),
                    "act": round(time.time() - written_at, 2), "at": time.time()}])[-10:]
        except SystemExit:
            raise
        except Exception as exc:  # 한 번의 실패로 듣기가 죽지 않게
            failures += 1
            common.log("오류: %r" % exc)
            if failures >= 3:
                # 받아쓰기 서버나 마이크가 죽었을 수 있다. 키보드 없이도 이어 쓰도록 한 번 새로 띄운다.
                recoveries = [t for t in recoveries if time.time() - t < 600] + [time.time()]
                try:
                    if len(recoveries) > 3:
                        raise RuntimeError("10분 안에 세 번 넘게 다시 띄웠습니다")
                    mic = restart(cfg)
                    failures = 0
                    common.log("→ 받아쓰기와 마이크를 다시 띄웠습니다")
                    common.say("핸즈프리를 다시 시작했습니다", cfg)
                except Exception as fatal:
                    common.log("시작 실패: %r" % fatal)
                    common.notify("handsfree", "오류가 반복돼 종료합니다. handsfree log 확인")
                    common.say("핸즈프리가 오류로 종료됩니다. 키보드로 다시 켜 주세요", cfg)
                    shutdown()
            time.sleep(1)


if __name__ == "__main__":
    main()
