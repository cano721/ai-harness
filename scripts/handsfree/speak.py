#!/usr/bin/env python3
"""Claude Code 훅(Stop·PermissionRequest·Notification)에서 불린다.
세션별 마지막 답변과 승인 요청 내용을 적어 두고, 읽어 주기가 켜져 있으면 소리로 알린다.
훅 출력이 결정으로 해석되지 않게 아무것도 출력하지 않는다."""
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
import orca  # noqa: E402
import reading  # noqa: E402


def last_assistant_text(transcript_path):
    try:
        with open(transcript_path, encoding="utf-8") as f:
            lines = f.readlines()[-200:]
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant":
            continue
        parts = entry.get("message", {}).get("content", [])
        if not isinstance(parts, list):
            continue
        text = " ".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text")
        if text.strip():
            return text
    return ""


def describe_request(data):
    """승인 요청을 한 줄로: 도구 이름과 무엇을 하려는지."""
    tool = data.get("tool_name", "")
    params = data.get("tool_input")
    if not isinstance(params, dict):
        params = {}
    if tool == "Bash":
        detail = params.get("description") or ""
        command = " ".join(str(params.get("command", "")).split())[:300]
        return "명령 실행. %s%s" % (detail + ". " if detail else "", command)
    if tool in ("Edit", "Write", "NotebookEdit"):
        return "파일 수정. " + os.path.basename(str(params.get("file_path", "")))
    if tool == "AskUserQuestion":
        questions = params.get("questions") or [{}]
        return "질문. " + str(questions[0].get("question", ""))
    return "%s 도구 사용" % tool if tool else ""


def main():
    if os.environ.get("HANDSFREE_INTERNAL"):
        return
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    handle = os.environ.get("ORCA_TERMINAL_HANDLE")
    if not handle or not common.listener_pid():
        return
    cfg = common.load_config()
    event = data.get("hook_event_name")
    here = handle == common.load_state().get("current")
    spoken = ""
    record = common.read_json(common.session_file(handle), {})
    # "N번 끝나면 알려 줘"로 부탁받은 세션은 읽어 주기 설정과 상관없이 한 번 알린다.
    asked = bool(record.get("notify_done")) and event in ("Stop", "PermissionRequest")

    if event == "UserPromptSubmit":
        # 키보드로 친 세션을 음성 입력 대상으로 삼는다. 음성으로 보낸 프롬프트는 제외한다.
        if not cfg.get("follow_keyboard"):
            return
        state = common.load_state()
        last = state.get("last_sent") or {}
        prompt = " ".join(str(data.get("prompt", "")).split())
        voiced = last.get("handle") == handle and " ".join(str(last.get("text", "")).split()) == prompt \
            and time.time() - last.get("at", 0) < 20
        if not voiced and state.get("current") != handle:
            common.update_state(current=handle)
            common.log("→ 키보드로 입력한 세션을 음성 입력 대상으로 바꿈")
        return
    if event == "Stop":
        text = data.get("last_assistant_message") or last_assistant_text(data.get("transcript_path", ""))
        text = reading.clean(text or "", cfg["wake_words"])
        if not text:
            return
        piece, offset = reading.chunk(text, 0, int(cfg.get("tts_max_chars", 220)))
        common.update_session(handle, last=text, offset=offset, pending="", danger=False)
        if asked:
            common.update_session(handle, notify_done=False)
            common.say("%s 끝났습니다" % session_name(handle), cfg)
            return
        if here and cfg.get("tts") and cfg.get("tts_summary") and not common.paused_until():
            # 요약은 몇 초 걸려 훅을 붙잡지 않도록 따로 띄운다.
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "--summarize", handle],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            return
        spoken = piece if here else "끝났습니다"
    elif event == "PermissionRequest":
        summary = reading.clean(describe_request(data), cfg["wake_words"])
        params = data.get("tool_input")
        command = str(params.get("command", "")).lower() if isinstance(params, dict) else ""
        danger = any(p.lower() in command for p in cfg.get("danger_patterns", []))
        common.update_session(handle, pending=summary, pending_at=time.time(), danger=danger)
        spoken = ("위험할 수 있는 명령입니다. " if danger else "") + "승인이 필요합니다. " + summary
        if asked:
            common.say("%s %s" % (session_name(handle), spoken), cfg)
            return
    elif event == "Notification":
        if "permission" not in data.get("message", "").lower():
            return
        session = common.read_json(common.session_file(handle), {})
        if time.time() - session.get("pending_at", 0) < 60:
            return
        spoken = "승인이 필요합니다"
    else:
        return

    if not spoken or not cfg.get("tts") or common.paused_until():
        return
    if not here:
        if not cfg.get("tts_other_sessions"):
            return
        number = next((i + 1 for i, s in enumerate(orca.sessions()) if s["handle"] == handle), None)
        if number is None:
            return
        spoken = "%d번 세션, %s" % (number, spoken)
    common.say(spoken, cfg)


def session_name(handle):
    number = next((i + 1 for i, s in enumerate(orca.sessions()) if s["handle"] == handle), None)
    return "%d번 세션" % number if number else "세션"


def summarize_and_say(handle):
    import ai
    cfg = common.load_config()
    record = common.read_json(common.session_file(handle), {})
    text = record.get("last", "")
    if not text:
        return
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()
    if record.get("summary") and record.get("summary_of") == digest:
        common.say(reading.clean(record["summary"], cfg["wake_words"]), cfg)
        return
    summary = ai.summarize(text, cfg)
    if summary:
        common.update_session(handle, summary=summary, summary_of=digest)
        common.say(reading.clean(summary, cfg["wake_words"]), cfg)
    else:
        common.say(reading.chunk(text, 0, int(cfg.get("tts_max_chars", 220)))[0], cfg)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summarize":
        try:
            summarize_and_say(sys.argv[2])
        except Exception as exc:
            common.log("요약 오류: %r" % exc)
        sys.exit(0)
    try:
        main()
    except Exception as exc:  # 훅 실패가 세션을 방해하지 않게
        common.log("훅 오류: %r" % exc)
