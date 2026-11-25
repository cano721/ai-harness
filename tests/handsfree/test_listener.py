"""듣기 프로그램의 판단 흐름. Orca·소리·설정 저장은 가짜로 바꿔 실제 세션에 아무것도 보내지 않는다."""
import json
import os
import sys
import time
import unittest

# 저장소의 scripts/handsfree 를 읽는다(tests/handsfree/ → 저장소 루트 → scripts/handsfree).
CODE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "scripts", "handsfree")
sys.path.insert(0, CODE)
import ai  # noqa: E402
import common  # noqa: E402
import listener  # noqa: E402
import orca  # noqa: E402

orca._real_sessions = orca.sessions

with open(os.path.join(CODE, "defaults.json"), encoding="utf-8") as f:
    DEFAULTS = json.load(f)

RULE = "─" * 60
IDLE = "⏺ 끝났습니다\n%s\n❯ \n%s\n  ⏵⏵ auto mode on" % (RULE, RULE)


def dialog_screen(body="Bash command\n  ls -la\n  List files", options=None):
    options = options or ["Yes", "Yes, and don't ask again for ls commands", "No"]
    lines = [" %s %d. %s" % ("❯" if i == 0 else " ", i + 1, text) for i, text in enumerate(options)]
    return "⏺ 작업\n%s\n %s\n Do you want to proceed?\n%s\n Esc to cancel · Tab to amend" % (RULE, body, "\n".join(lines))


class Harness(unittest.TestCase):
    def setUp(self):
        self.sessions = [{"handle": "t%d" % i, "title": name, "tab": name}
                         for i, name in enumerate(["로그 수집", "결제 리팩터링", "문서 정리"], 1)]
        self.screens = {s["handle"]: IDLE for s in self.sessions}
        self.sent, self.said, self.state, self.records, self.saved = [], [], {"current": "t1"}, {}, {}
        self.paused = [0]
        self.ai_answer = None
        self.cfg = dict(DEFAULTS, config_broken=False)
        listener.mem.update(armed_until=0, pending=None, config_warned=False, screens={})

        orca.sessions = lambda: list(self.sessions)
        orca.screen = lambda handle: self.screens.get(handle)
        orca.send = lambda handle, text, enter=False: self.sent.append((handle, text, enter)) or True
        orca.switch = lambda handle: True
        ai.classify = lambda text, dlg, cfg: self.ai_answer
        common.say = lambda text, cfg: self.said.append(text)
        common.notify = lambda *a: None
        common.beep = lambda *a: None
        common.log = lambda *a: None
        common.is_speaking = lambda: False
        common.spoke_since = lambda moment: False
        common.stop_speaking = lambda: self.said.append("<읽기 멈춤>")
        common.load_state = lambda: dict(self.state)
        common.update_state = lambda **changes: self.state.update(changes)
        common.read_json = lambda path, fallback: self.records.get(os.path.basename(path)[:-5], fallback)
        common.update_session = lambda handle, **changes: self.records.setdefault(handle, {}).update(changes)
        common.set_user_config = lambda key, value: self.saved.update({key: value}) or True
        common.paused_until = lambda: self.paused[0]
        common.set_paused = lambda until: self.paused.__setitem__(0, until)
        common.load_config = lambda: self.cfg

    def hear(self, text, **kw):
        self.said.clear()
        listener.handle_text(text, self.cfg, **kw)

    def heard(self, fragment):
        self.assertTrue(any(fragment in line for line in self.said), "%r 없음: %s" % (fragment, self.said))


class FollowFocusTest(Harness):
    def click(self, handle):
        for s in self.sessions:
            s["active"] = s["handle"] == handle

    def test_clicked_tab_becomes_target(self):
        self.click("t3")
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.assertEqual(self.sent, [("t3", "테스트 돌려 줘", True)])

    def test_unchanged_front_tab_keeps_voice_choice(self):
        # 앞 탭이 그대로면 "1번 세션"이나 키보드로 정한 대상을 덮지 않는다.
        self.click("t3")
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.state["current"] = "t1"
        self.hear("헤이 클로드, 로그 봐 줘")
        self.assertEqual(self.sent[-1], ("t1", "로그 봐 줘", True))

    def test_off_or_split_view_does_not_follow(self):
        self.cfg["follow_focus"] = False
        self.click("t2")
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.cfg["follow_focus"] = True
        for s in self.sessions:
            s["active"] = False
        self.hear("헤이 클로드, 로그 봐 줘")
        self.assertEqual([h for h, _, _ in self.sent], ["t1", "t1"])

    def test_sessions_reads_front_tab_from_orca(self):
        layout = {"result": {"visualLayouts": [{"root": {"type": "group", "activeTabId": "B", "tabs": [
            {"tabId": "A", "title": "가", "activeLeafId": "a2", "panes": {"type": "split", "children": [
                {"type": "terminal", "handle": "ta1", "leafId": "a1", "title": "가1"},
                {"type": "terminal", "handle": "ta2", "leafId": "a2", "title": "가2"}]}},
            {"tabId": "B", "title": "나", "activeLeafId": "b1",
             "panes": {"type": "terminal", "handle": "tb1", "leafId": "b1", "title": "나1"}}]}}]}}
        real_sessions, real_run = orca._real_sessions, orca._run
        try:
            orca._run = lambda *a, **k: type("R", (), {"stdout": json.dumps(layout)})()
            self.assertEqual(real_sessions(), [
                {"handle": "ta2", "title": "가2", "tab": "가", "active": False},
                {"handle": "tb1", "title": "나1", "tab": "나", "active": True}])
        finally:
            orca._run = real_run


class PromptTest(Harness):
    def test_prompt_goes_to_current_session(self):
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.assertEqual(self.sent, [("t1", "테스트 돌려 줘", True)])

    def test_no_wake_word_sends_nothing(self):
        self.hear("테스트 돌려 줘")
        self.hear("승인")
        self.assertEqual(self.sent, [])

    def test_prompt_is_not_typed_into_dialog(self):
        self.screens["t1"] = dialog_screen()
        self.hear("헤이 클로드, 로그도 같이 정리해 줘")
        self.assertEqual(self.sent, [])
        self.heard("보내지 않았습니다")

    def test_unknown_screen_sends_nothing(self):
        # 승인 창 모양이 바뀌어 못 알아봐도, 입력 칸이 안 보이면 글자와 엔터를 보내지 않는다.
        self.screens["t1"] = "⏺ 작업\n Do you want to proceed?\n > Yes\n   No\n (new footer)"
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.hear("헤이 클로드 보내")
        self.assertEqual(self.sent, [])
        self.heard("입력 칸")

    def test_titled_input_box(self):
        self.screens["t1"] = "⏺ 끝\n%s 결제 작업 ─\n❯ \n%s\n  🎙 듣는 중\n  ⏵⏵ auto mode on" % ("─" * 60, "─" * 60)
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.assertEqual(self.sent, [("t1", "테스트 돌려 줘", True)])

    def test_unreadable_screen_sends_nothing(self):
        self.screens["t1"] = None
        self.hear("헤이 클로드, 테스트 돌려 줘")
        self.hear("헤이 클로드 승인")
        self.hear("헤이 클로드 보내")
        self.assertEqual(self.sent, [])

    def test_targeted_prompt_keeps_current_session(self):
        self.hear("헤이 클로드 3번 세션에 진행 상황 알려 줘")
        self.assertEqual(self.sent, [("t3", "진행 상황 알려 줘", True)])
        self.assertEqual(self.state["current"], "t1")

    def test_named_target_asks_first(self):
        self.hear("헤이 클로드 문서 정리 세션에 만료 시간 추가해 줘")
        self.assertEqual(self.sent, [])
        self.heard("보낼까요")
        self.hear("헤이 클로드 보내")
        self.assertEqual(self.sent, [("t3", "만료 시간 추가해 줘", True)])

    def test_truncated_utterance_is_not_sent(self):
        self.hear("헤이 클로드 전부 지우고", truncated=True)
        self.assertEqual(self.sent, [])
        self.heard("잘렸습니다")


class DialogTest(Harness):
    def setUp(self):
        Harness.setUp(self)
        self.screens["t1"] = dialog_screen()

    def test_approve_and_deny(self):
        self.hear("헤이 클로드 승인")
        self.assertEqual(self.sent, [("t1", "\r", False)])
        self.sent.clear()
        self.hear("헤이 클로드 하지 마")
        self.assertEqual(self.sent, [("t1", "\x1b", False)])

    def test_broad_option_cannot_be_chosen(self):
        self.hear("헤이 클로드 2번")
        self.assertEqual(self.sent, [])
        self.heard("음성으로는 고를 수 없습니다")
        self.hear("헤이 클로드 3번")
        self.assertEqual(self.sent, [("t1", "3", False)])

    def test_missing_option(self):
        self.hear("헤이 클로드 7번")
        self.assertEqual(self.sent, [])

    def test_enter_does_not_confirm_dialog(self):
        self.hear("헤이 클로드 보내")
        self.assertEqual(self.sent, [])

    def test_dangerous_command_needs_explicit_phrase(self):
        self.screens["t1"] = dialog_screen("Bash command\n  git push --force origin main\n  Force push")
        self.hear("헤이 클로드 승인")
        self.assertEqual(self.sent, [])
        self.heard("확실히 승인")
        self.hear("헤이 클로드 확실히 승인")
        self.assertEqual(self.sent, [("t1", "\r", False)])

    def test_question_dialog_is_not_approved_by_yes(self):
        self.screens["t1"] = dialog_screen("어느 방식으로 할까요?", ["Redis 캐시", "DB 조회", "둘 다"])
        self.hear("헤이 클로드 승인")
        self.assertEqual(self.sent, [])
        self.heard("번호로 골라")
        self.hear("헤이 클로드 2번")
        self.assertEqual(self.sent, [("t1", "2", False)])

    def test_cursor_moved_off_yes(self):
        self.screens["t1"] = self.screens["t1"].replace(" ❯ 1. Yes", "   1. Yes").replace("   3. No", " ❯ 3. No")
        self.hear("헤이 클로드 승인")
        self.assertEqual(self.sent, [])

    def test_ai_guess_is_confirmed_before_acting(self):
        self.ai_answer = {"type": "choose", "number": 3}
        self.hear("헤이 클로드 마지막 걸로 해 줘")
        self.assertEqual(self.sent, [])
        self.heard("이걸로 고를까요")
        self.hear("맘마 먹자")
        self.hear("응")
        self.assertEqual(self.sent, [])
        self.hear("헤이 클로드 응")
        self.assertEqual(self.sent, [("t1", "3", False)])

    def test_ai_unclear_sends_nothing(self):
        self.ai_answer = {"type": "unclear"}
        self.hear("헤이 클로드 그건 좀 위험하지 않나")
        self.assertEqual(self.sent, [])

    def test_approve_other_session(self):
        self.state["current"] = "t2"
        self.hear("헤이 클로드 승인")
        self.assertEqual(self.sent, [])
        self.heard("1번 세션")
        self.hear("헤이 클로드 1번 세션 승인")
        self.assertEqual(self.sent, [("t1", "\r", False)])

    def test_targeted_approve_without_dialog(self):
        self.hear("헤이 클로드 2번 세션 승인")
        self.assertEqual(self.sent, [])
        self.heard("승인 창이 없습니다")


class NoDialogTest(Harness):
    def test_reply_words_go_as_text_when_no_dialog_anywhere(self):
        self.hear("헤이 클로드 그러자")
        self.assertEqual(self.sent, [("t1", "그러자", True)])

    def test_explain_without_dialog(self):
        self.hear("헤이 클로드 뭐 승인하는 거야")
        self.heard("승인 창이 없습니다")


class WindowTest(Harness):
    def test_prompt_after_calling(self):
        self.hear("헤이 클로드")
        self.hear("스킬 전문 보여 줘")
        self.assertEqual(self.sent, [("t1", "스킬 전문 보여 줘", True)])
        self.sent.clear()
        self.hear("그다음 말은 호출어가 없다")
        self.assertEqual(self.sent, [])

    def test_confirm_answer_without_wake_word(self):
        self.cfg["confirm_before_send"] = True
        self.hear("헤이 클로드 릴리즈 노트 써 줘")
        self.hear("응")
        self.hear("아가 맘마 먹자")
        self.assertEqual(self.sent, [])
        self.hear("보내")
        self.assertEqual(self.sent, [("t1", "릴리즈 노트 써 줘", True)])

    def test_armed_approve_is_refused(self):
        self.screens["t1"] = dialog_screen()
        self.hear("헤이 클로드")
        self.hear("승인")
        self.assertEqual(self.sent, [])
        self.heard("호출어와 함께")

    def test_window_counts_from_speech_start(self):
        self.hear("헤이 클로드")
        self.hear("늦게 시작한 말", started_at=time.time() + 60)
        self.assertEqual(self.sent, [])
        self.assertIsNone(listener.mem["pending"])

    def test_confirm_expires(self):
        self.cfg["confirm_before_send"] = True
        self.hear("헤이 클로드 릴리즈 노트 써 줘")
        listener.mem["pending"]["expires"] = time.time() - 1
        self.hear("헤이 클로드 네")
        self.assertEqual(self.sent, [])
        self.heard("시간이 지나")


class AliasTest(Harness):
    def setUp(self):
        Harness.setUp(self)
        self.cfg["aliases"] = {"결제": "결제 리팩터링", "셋": 3, "없음": "없는 탭"}

    def test_alias_prompt_and_goto(self):
        self.hear("헤이 클로드 결제에 진행 상황 알려 줘")
        self.assertEqual(self.sent, [("t2", "진행 상황 알려 줘", True)])
        self.hear("헤이 클로드 셋으로 가")
        self.assertEqual(self.state["current"], "t3")

    def test_alias_approve(self):
        self.screens["t2"] = dialog_screen()
        self.hear("헤이 클로드 결제 승인")
        self.assertEqual(self.sent, [("t2", "\r", False)])

    def test_missing_alias_target(self):
        self.hear("헤이 클로드 없음에 테스트 돌려 줘")
        self.assertEqual(self.sent, [])
        self.heard("찾지 못했습니다")


class NotifyTest(Harness):
    def test_marks_busy_session(self):
        self.screens["t2"] = IDLE.replace("auto mode on", "auto mode on · esc to interrupt")
        self.hear("헤이 클로드 2번 끝나면 알려 줘")
        self.assertTrue(self.records["t2"]["notify_done"])
        self.heard("알려 드리겠습니다")

    def test_idle_session_is_told(self):
        self.hear("헤이 클로드 끝나면 알려 줘")
        self.assertNotIn("t1", self.records)
        self.heard("하는 일이 없습니다")

    def test_not_a_session_name_goes_as_prompt(self):
        self.hear("헤이 클로드 빌드 끝나면 알려 줘")
        self.assertEqual(self.sent, [("t1", "빌드 끝나면 알려 줘", True)])


class DictationTest(Harness):
    def test_collect_and_send(self):
        self.hear("헤이 클로드 길게 말할게")
        self.hear("로그 수집 구조를 바꾸려고 하는데")
        self.hear("우선 현재 토픽 목록부터 정리해 줘")
        self.assertEqual(self.sent, [])
        self.hear("보내")
        self.assertEqual(self.sent, [("t1", "로그 수집 구조를 바꾸려고 하는데 우선 현재 토픽 목록부터 정리해 줘", True)])
        self.assertIsNone(listener.mem["dictation"])

    def test_cancel(self):
        self.hear("헤이 클로드 길게 말할게")
        self.hear("이건 보내면 안 되는 말")
        self.hear("헤이 클로드 취소")
        self.assertEqual(self.sent, [])
        self.assertIsNone(listener.mem["dictation"])

    def test_truncated_pieces_are_kept(self):
        self.hear("헤이 클로드 길게 말할게")
        self.hear("아주 긴 설명", truncated=True)
        self.hear("끝")
        self.assertEqual(self.sent, [("t1", "아주 긴 설명", True)])

    def test_idle_asks_instead_of_dropping(self):
        self.hear("헤이 클로드 길게 말할게")
        self.hear("테스트 정리")
        listener.mem["dictation"]["last"] = time.time() - 999
        common.load_config = lambda: self.cfg
        import threading
        stop = threading.Event()
        original_sleep = time.sleep
        time.sleep = lambda s: (stop.set(), original_sleep(0)) if stop.is_set() else stop.set()
        try:
            thread = threading.Thread(target=listener.watch_dictation, daemon=True)
            thread.start()
            thread.join(0.3)
        finally:
            time.sleep = original_sleep
        self.assertEqual(self.sent, [])
        self.assertIsNotNone(listener.mem["pending"])
        self.hear("보내")
        self.assertEqual(self.sent, [("t1", "테스트 정리", True)])


class PauseTest(Harness):
    def test_pause_blocks_everything_but_resume(self):
        self.hear("헤이 클로드 잠깐 꺼")
        self.assertTrue(self.paused[0])
        self.hear("헤이 클로드 테스트 돌려 줘")
        self.assertEqual(self.sent, [])
        self.heard("쉬는 중")
        self.hear("헤이 클로드 다시 켜")
        self.assertFalse(self.paused[0])

    def test_stop_phrase_only_pauses(self):
        self.hear("헤이 클로드 듣기 그만")
        self.assertTrue(self.paused[0])

    def test_zero_minutes(self):
        self.hear("헤이 클로드 0분 쉬어")
        self.assertFalse(self.paused[0])


class SpeakingTest(Harness):
    def test_wake_word_inside_speech_stops_reading(self):
        common.is_speaking = lambda: True
        self.hear("다음 단계는 검증입니다 헤이 클로드 조용")
        self.assertIn("<읽기 멈춤>", self.said)
        self.assertEqual(self.sent, [])

    def test_stop_word_while_reading_does_not_interrupt_session(self):
        common.is_speaking = lambda: True
        self.hear("헤이 클로드 그만")
        self.assertEqual(self.sent, [])
        self.assertIn("<읽기 멈춤>", self.said)


class MiscTest(Harness):
    def test_undo_targets_last_sent_session(self):
        self.hear("헤이 클로드 3번 세션에 빌드해 줘")
        self.sent.clear()
        self.hear("헤이 클로드 방금 거 취소")
        self.assertEqual(self.sent, [("t3", "\x1b", False)])

    def test_session_switch(self):
        self.hear("헤이 클로드 2번 세션")
        self.assertEqual(self.state["current"], "t2")
        self.hear("헤이 클로드 다음 세션")
        self.assertEqual(self.state["current"], "t3")
        self.hear("헤이 클로드 9번 세션")
        self.assertEqual(self.state["current"], "t3")

    def test_lost_current_session(self):
        self.state["current"] = "gone"
        self.hear("헤이 클로드 테스트 돌려 줘")
        self.hear("헤이 클로드 다음 세션")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state["current"], "gone")

    def test_status_reports_waiting_sessions(self):
        self.screens["t2"] = dialog_screen()
        self.hear("헤이 클로드 세션 상태")
        self.heard("2번 승인 대기")

    def test_broken_config_is_announced_once(self):
        self.cfg["config_broken"] = True
        self.hear("헤이 클로드 세션 목록")
        self.heard("설정 파일")


if __name__ == "__main__":
    unittest.main()
