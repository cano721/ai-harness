import json
import os
import sys
import unittest

# 저장소의 scripts/handsfree 를 읽는다(tests/handsfree/ → 저장소 루트 → scripts/handsfree).
CODE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "scripts", "handsfree")
sys.path.insert(0, CODE)
import orca  # noqa: E402
import reading  # noqa: E402
from router import has_wake, route, squash, wake_variants  # noqa: E402

with open(os.path.join(CODE, "defaults.json"), encoding="utf-8") as f:
    CFG = json.load(f)

DIALOG = """⏺ Write(/private/tmp/a.txt)
────────────────────────────────────────────────────────────
 Create file
 ../../../private/tmp/a.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1. 첫째
  5. 다섯째
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create a.txt?
 ❯ 1. Yes
   2. Yes, and don't ask again for this session
   3. No
 Esc to cancel · Tab to amend"""


class RouterTest(unittest.TestCase):
    def t(self, text, armed=False):
        return route(text, CFG, armed)

    def kind(self, text, armed=False):
        return self.t(text, armed)["type"]

    def test_no_wake_word_is_ignored(self):
        for text in ["우리 아기 잘 잤어?", "승인", "시청해주셔서 감사합니다.", "어제 클로드 써 봤어",
                     "클로드 요즘 좋더라", "클로드"]:
            self.assertEqual(self.kind(text), "ignore", text)

    def test_talking_about_claude_is_not_calling(self):
        for text in ["헤이 클로드는 요즘 좋더라", "헤이 클로드한테 물어볼까", "hey claudette is here"]:
            self.assertEqual(self.kind(text), "ignore", text)

    def test_wake_variants(self):
        for text in ["헤이, 클로드. 테스트 돌려 줘", "헤이클로드 테스트 돌려 줘", "Hey, Claude. 테스트 돌려 줘",
                     "- 헤이 클로드, 테스트 돌려 줘", "헤이 클로드야, 테스트 돌려 줘",
                     "헤이 클로드, 헤이 클로드 테스트 돌려 줘"]:
            self.assertEqual(self.t(text), {"type": "prompt", "text": "테스트 돌려 줘"}, text)
        self.assertEqual(self.kind("헤이 클로드."), "wake_only")
        self.assertEqual(route("아무 말", dict(CFG, wake_words=["", " "]))["type"], "ignore")

    def test_wake_inside_sentence(self):
        self.assertTrue(has_wake("다음 단계는 검증입니다 헤이 클로드 조용", CFG["wake_words"]))
        self.assertFalse(has_wake("다음 단계는 검증입니다", CFG["wake_words"]))

    def test_armed_marks_action(self):
        self.assertEqual(self.t("테스트 돌려 줘", armed=True), {"type": "prompt", "text": "테스트 돌려 줘", "armed": True})
        self.assertNotIn("armed", self.t("헤이 클로드 테스트 돌려 줘", armed=True))

    def test_prompt(self):
        self.assertEqual(self.t("헤이 클로드, #42 PR 올려 줘."), {"type": "prompt", "text": "#42 PR 올려 줘"})
        for text in ["하지 말고 테스트부터 돌려", "좋아 그럼 PR 올려", "이 세션에서 한 일 요약해 줘"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "prompt", text)

    def test_approve_is_explicit(self):
        for text in ["승인", "허용해 줘", "어 그러자", "알겠어요", "진행해", "오케이"]:
            self.assertEqual(self.kind("헤이 클로드, " + text), "approve", text)
        # 망설임·맞장구·반대말과 한 음절 차이인 말은 승인이 아니다.
        for text in ["어", "응", "해", "고", "네", "계속", "확인", "괜찮아", "해도 돼", "한번", "이번"]:
            self.assertEqual(self.kind("헤이 클로드, " + text), "prompt", text)

    def test_deny_and_interrupt(self):
        for text in ["거절", "하지 마", "안 할 거야", "싫어요"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "deny", text)
        for text in ["중단", "그만해 줘", "취소"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "interrupt", text)
        for text in ["잠깐만", "기다려 봐"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "prompt", text)

    def test_choose(self):
        for text, number in [("2번", 2), ("삼 번", 3), ("두 번째", 2), ("세 번째 걸로 해", 3), ("1번으로 해 줘", 1)]:
            action = self.t("헤이 클로드 " + text)
            self.assertEqual((action["type"], action.get("number")), ("choose", number), text)

    def test_sessions(self):
        self.assertEqual(self.t("헤이 클로드 3번 세션"), {"type": "goto_session", "index": 3})
        self.assertEqual(self.t("헤이 클로드, 세 번 세션으로 가줘")["index"], 3)
        self.assertEqual(self.kind("헤이 클로드 다음 세션"), "next_session")
        self.assertEqual(self.kind("헤이 클로드 다음"), "prompt")
        named = self.t("헤이 클로드 결제 세션으로 이동")
        self.assertEqual((named["type"], named["name"]), ("goto_session_named", "결제"))

    def test_wake_variants(self):
        for text in ["헤이, 클로드. 테스트 돌려 줘", "헤이클로드 테스트 돌려 줘", "Hey, Claude. 테스트 돌려 줘",
                     "- 헤이 클로드, 테스트 돌려 줘", "헤이 클로드야, 테스트 돌려 줘",
                     "헤이 클로드, 헤이 클로드 테스트 돌려 줘"]:
            self.assertEqual(self.t(text), {"type": "prompt", "text": "테스트 돌려 줘"}, text)
        self.assertEqual(self.kind("헤이 클로드."), "wake_only")
        self.assertEqual(route("아무 말", dict(CFG, wake_words=["", " "]))["type"], "ignore")

    def test_wake_inside_sentence(self):
        self.assertTrue(has_wake("다음 단계는 검증입니다 헤이 클로드 조용", CFG["wake_words"]))
        self.assertFalse(has_wake("다음 단계는 검증입니다", CFG["wake_words"]))

    def test_armed_marks_action(self):
        self.assertEqual(self.t("테스트 돌려 줘", armed=True), {"type": "prompt", "text": "테스트 돌려 줘", "armed": True})
        self.assertNotIn("armed", self.t("헤이 클로드 테스트 돌려 줘", armed=True))

    def test_prompt(self):
        self.assertEqual(self.t("헤이 클로드, NJ-3550 PR 올려 줘."), {"type": "prompt", "text": "NJ-3550 PR 올려 줘"})
        for text in ["하지 말고 테스트부터 돌려", "좋아 그럼 PR 올려", "이 세션에서 한 일 요약해 줘"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "prompt", text)

    def test_approve_is_explicit(self):
        for text in ["승인", "허용해 줘", "어 그러자", "알겠어요", "진행해", "오케이"]:
            self.assertEqual(self.kind("헤이 클로드, " + text), "approve", text)
        # 망설임·맞장구·반대말과 한 음절 차이인 말은 승인이 아니다.
        for text in ["어", "응", "해", "고", "네", "계속", "확인", "괜찮아", "해도 돼", "한번", "이번"]:
            self.assertEqual(self.kind("헤이 클로드, " + text), "prompt", text)

    def test_deny_and_interrupt(self):
        for text in ["거절", "하지 마", "안 할 거야", "싫어요"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "deny", text)
        for text in ["중단", "그만해 줘", "취소"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "interrupt", text)
        for text in ["잠깐만", "기다려 봐"]:
            self.assertEqual(self.kind("헤이 클로드 " + text), "prompt", text)

    def test_choose(self):
        for text, number in [("2번", 2), ("삼 번", 3), ("두 번째", 2), ("세 번째 걸로 해", 3), ("1번으로 해 줘", 1)]:
            action = self.t("헤이 클로드 " + text)
            self.assertEqual((action["type"], action.get("number")), ("choose", number), text)

    def test_sessions(self):
        self.assertEqual(self.t("헤이 클로드 3번 세션"), {"type": "goto_session", "index": 3})
        self.assertEqual(self.t("헤이 클로드, 세 번 세션으로 가줘")["index"], 3)
        self.assertEqual(self.kind("헤이 클로드 다음 세션"), "next_session")
        self.assertEqual(self.kind("헤이 클로드 다음"), "prompt")
        named = self.t("헤이 클로드 잡다로그 세션으로 이동")
        self.assertEqual((named["type"], named["name"]), ("goto_session_named", "잡다로그"))

    def test_wake_variants(self):
        found = wake_variants("헤이 클로드")
        for shape in ["에이 클로드", "애이 클로드", "헤이 끌로드", "hey claude", "에이 클라우드"]:
            self.assertIn(shape, found)
        self.assertNotIn("헤이 클로드", found)
        # 한 단어 안에서는 한 음절만, 초성·중성 중 한쪽만 바꾼다.
        self.assertNotIn("헤이 끌로뜨", found)
        self.assertEqual(wake_variants("자비스")[:1], ["jarvis"])
        self.assertIn("짜비스", wake_variants("자비스"))
        self.assertLessEqual(len(wake_variants("오케이 비서 님")), 60)

    def test_this_session_is_not_session_two(self):
        for text in ["이번 세션에 한 일 정리해 줘", "이번 세션", "한번 세션 봐 줘"]:
            action = self.t("헤이 클로드 " + text)
            self.assertNotEqual(action.get("index"), 2, text)
            self.assertNotEqual(action["type"], "goto_session", text)

    def test_targeted(self):
        self.assertEqual(self.t("헤이 클로드 3번 세션에 테스트 돌려 줘"),
                         {"type": "prompt", "text": "테스트 돌려 줘", "index": 3})
        self.assertEqual(self.t("헤이 클로드 3번 세션 승인"), {"type": "approve", "spoken": "승인", "index": 3})
        self.assertEqual(self.t("헤이 클로드 3번 세션에 승인")["type"], "approve")
        self.assertEqual(self.t("헤이 클로드 5번 세션 하지 마")["type"], "deny")
        named = self.t("헤이 클로드 결제 리팩터링 세션에 진행 상황 알려 줘")
        self.assertEqual((named["session_name"], named["text"], named["ask_first"]),
                         ("결제 리팩터링", "진행 상황 알려 줘", True))

    def test_pause(self):
        self.assertEqual(self.t("헤이 클로드 5분 쉬어"), {"type": "pause", "minutes": 5})
        self.assertEqual(self.t("헤이 클로드 30분만 꺼 줘")["minutes"], 30)
        self.assertEqual(self.kind("헤이 클로드 잠깐 꺼"), "pause")
        self.assertEqual(self.kind("헤이 클로드 듣기 그만"), "pause")
        self.assertEqual(self.kind("헤이 클로드 다시 켜"), "resume")

    def test_other_commands(self):
        cases = {"뭐 승인하는 거야?": "explain_dialog", "방금 거 취소": "undo", "계속 읽어 줘": "read_more",
                 "읽어 줘": "read_last", "조용": "stop_speaking", "읽어 줘 켜": "tts_on", "세션 상태": "status_all",
                 "듣고 있어?": "ping", "확실히 승인": "approve_force", "확인 모드 켜": "confirm_on", "보내": "enter"}
        for text, kind in cases.items():
            self.assertEqual(self.kind("헤이 클로드 " + text), kind, text)

    def test_no_phrase_belongs_to_two_actions(self):
        seen = {}
        for action, phrases in CFG["commands"].items():
            for phrase in phrases:
                self.assertNotIn(squash(phrase), seen, "%s: %s / %s" % (phrase, action, seen.get(squash(phrase))))
                seen[squash(phrase)] = action

    def test_aliases(self):
        cfg = dict(CFG, aliases={"결제": "결제 리팩터링", "문서": 4})
        self.assertEqual(route("헤이 클로드 결제에 테스트 돌려 줘", cfg),
                         {"type": "prompt", "text": "테스트 돌려 줘", "alias": "결제"})
        self.assertEqual(route("헤이 클로드 결제 승인", cfg)["type"], "approve")
        self.assertEqual(route("헤이 클로드 결제 승인", cfg)["alias"], "결제")
        self.assertEqual(route("헤이 클로드 문서로 이동해 줘", cfg)["type"], "goto_session_named")
        # 별명으로 시작해도 조사나 이동 말이 없으면 현재 세션에 보내는 프롬프트다.
        self.assertEqual(route("헤이 클로드 결제 로그 정리해 줘", cfg), {"type": "prompt", "text": "결제 로그 정리해 줘"})
        self.assertEqual(route("헤이 클로드 결제", cfg)["type"], "prompt")

    def test_notify_done(self):
        cfg = dict(CFG, aliases={"결제": "결제 리팩터링"})
        self.assertEqual(route("헤이 클로드 3번 끝나면 알려 줘", cfg)["index"], 3)
        self.assertEqual(route("헤이 클로드 결제 끝나면 알려 줘", cfg)["alias"], "결제")
        self.assertNotIn("index", route("헤이 클로드 이거 다 되면 말해 줘", cfg))
        self.assertEqual(route("헤이 클로드 빌드 끝나면 알려 줘", cfg)["session_name"], "빌드")
        self.assertEqual(route("헤이 클로드 테스트 끝나면 결과 알려 줘", cfg)["type"], "prompt")

    def test_dictate(self):
        self.assertEqual(self.kind("헤이 클로드 길게 말할게"), "dictate")

    def test_macro_and_override(self):
        cfg = dict(CFG, macros={"일지 써 줘": "오늘 업무 일지 작성해 줘"})
        self.assertEqual(route("헤이 클로드 일지 써줘", cfg)["text"], "오늘 업무 일지 작성해 줘")


class ScreenTest(unittest.TestCase):
    def test_dialog(self):
        dlg = orca.dialog(DIALOG)
        self.assertEqual(sorted(dlg["options"]), [1, 2, 3])
        self.assertEqual(dlg["selected"], 1)
        self.assertIn("don't ask again", dlg["options"][2])

    def test_cursor_on_other_option(self):
        moved = DIALOG.replace(" ❯ 1. Yes", "   1. Yes").replace("   3. No", " ❯ 3. No")
        self.assertEqual(orca.dialog(moved)["selected"], 3)

    def test_not_a_dialog(self):
        idle = "⏺ 예시입니다\n ❯ 1. Yes\n   2. No\n" + "─" * 40 + "\n❯ \n" + "─" * 40 + "\n  ⏸ manual mode on"
        self.assertIsNone(orca.dialog(idle))
        self.assertIsNone(orca.dialog(""))
        self.assertIsNone(orca.dialog(None))
        self.assertEqual(orca.state_of(None), "확인 불가")


class ReadingTest(unittest.TestCase):
    def test_clean(self):
        text = reading.clean("**반영**했습니다. `a.py`\n\n| a | b |\n|---|---|\n헤이, 클로드. 승인", CFG["wake_words"])
        # 지켜야 할 것: 읽어 주는 소리를 마이크가 다시 들어도 명령이 되지 않는다.
        self.assertEqual(route(text, CFG)["type"], "ignore")
        self.assertFalse(has_wake(text, CFG["wake_words"]))
        self.assertNotIn("|", text)

    def test_clean_is_fast_on_long_blank_runs(self):
        import time
        started = time.time()
        reading.clean(" " * 5000 + "x\n" * 50, CFG["wake_words"])
        self.assertLess(time.time() - started, 0.5)


if __name__ == "__main__":
    unittest.main()
