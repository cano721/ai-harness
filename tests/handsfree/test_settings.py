"""상태 화면에서 오는 설정 변경 검증과 키보드 세션 따라가기."""
import io
import json
import os
import sys
import time
import unittest

# 저장소의 scripts/handsfree 를 읽는다(tests/handsfree/ → 저장소 루트 → scripts/handsfree).
CODE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "scripts", "handsfree")
sys.path.insert(0, CODE)
import common  # noqa: E402
import speak  # noqa: E402
import ui  # noqa: E402

with open(os.path.join(CODE, "defaults.json"), encoding="utf-8") as f:
    CFG = json.load(f)


class ValidateTest(unittest.TestCase):
    def test_numbers_and_bools(self):
        self.assertEqual(ui.validate({"silence_sec": 1.234}, CFG), {"silence_sec": 1.23})
        self.assertEqual(ui.validate({"mic_threshold": 2}, CFG), {"mic_threshold": "2%"})
        self.assertEqual(ui.validate({"wake_window_sec": 9.6}, CFG), {"wake_window_sec": 10})
        self.assertEqual(ui.validate({"tts": True, "silence_sec": None}, CFG), {"tts": True, "silence_sec": None})

    def test_rejects(self):
        for changes in [{"silence_sec": 9}, {"silence_sec": "1"}, {"tts": 1}, {"vocabulary": ["아무거나"]},
                        {"commands": {}}, {}, [], {"aliases": {"승인": "결제"}}, {"aliases": {"3번": "결제"}},
                        {"aliases": {"결제": ""}}, {"aliases": {"": "결제"}}]:
            with self.assertRaises(ValueError, msg=str(changes)):
                ui.validate(changes, CFG)

    def test_aliases(self):
        self.assertEqual(ui.validate({"aliases": {" 결제 ": "결제 리팩터링", "셋": 3}}, CFG),
                         {"aliases": {"결제": "결제 리팩터링", "셋": 3}})

    def test_wake_words(self):
        self.assertEqual(ui.validate({"wake_words": [" 자비스 ", "자 비스", "", "쟈비스"]}, CFG),
                         {"wake_words": ["자비스", "자 비스", "쟈비스"]})
        self.assertEqual(ui.validate({"wake_words": None}, CFG), {"wake_words": None})
        for words in [[], [""], ["어"], ["헤이"], ["승인해"], ["1234"], "자비스", [3]]:
            with self.assertRaises(ValueError, msg=str(words)):
                ui.validate({"wake_words": words}, CFG)

    def test_custom_wake_word_routes(self):
        from router import route
        cfg = dict(CFG, wake_words=["자비스", "쟈비스"])
        self.assertEqual(route("자비스, 테스트 돌려 줘", cfg), {"type": "prompt", "text": "테스트 돌려 줘"})
        self.assertEqual(route("쟈비스 승인", cfg)["type"], "approve")
        self.assertEqual(route("헤이 클로드 테스트 돌려 줘", cfg)["type"], "ignore")
        self.assertEqual(route("자비스는 영화에 나와", cfg)["type"], "ignore")

    def test_every_field_has_a_default(self):
        for key in ui.FIELDS:
            self.assertIn(key, CFG, key)


class MoreSettingsTest(unittest.TestCase):
    def test_percent_fields(self):
        self.assertEqual(ui.validate({"speech_volume": 60, "quiet_volume": 0}, CFG),
                         {"speech_volume": 0.6, "quiet_volume": 0.0})
        with self.assertRaises(ValueError):
            ui.validate({"beep_volume": 150}, CFG)

    def test_macros(self):
        self.assertEqual(ui.validate({"macros": {" 일지  써 줘 ": " 오늘 업무 일지 작성해 줘 "}}, CFG),
                         {"macros": {"일지 써 줘": "오늘 업무 일지 작성해 줘"}})
        for bad in [{"승인": "/commit"}, {"3번": "x"}, {"커밋": ""}, {"a": "x"}]:
            with self.assertRaises(ValueError, msg=str(bad)):
                ui.validate({"macros": bad}, CFG)

    def test_quiet_hours(self):
        cfg = dict(CFG, quiet_hours=True, quiet_from=22, quiet_to=7, speech_volume=1.0, quiet_volume=0.25)
        night = time.mktime((2026, 11, 21, 23, 30, 0, 0, 0, -1))
        noon = time.mktime((2026, 11, 21, 12, 0, 0, 0, 0, -1))
        dawn = time.mktime((2026, 11, 21, 6, 59, 0, 0, 0, -1))
        self.assertTrue(common.in_quiet_hours(cfg, night))
        self.assertTrue(common.in_quiet_hours(cfg, dawn))
        self.assertFalse(common.in_quiet_hours(cfg, noon))
        self.assertFalse(common.in_quiet_hours(dict(cfg, quiet_hours=False), night))
        self.assertTrue(common.in_quiet_hours(dict(cfg, quiet_from=13, quiet_to=15),
                                              time.mktime((2026, 11, 21, 14, 0, 0, 0, 0, -1))))

    def test_wake_suggestions(self):
        import tempfile
        log = tempfile.mktemp()
        with open(log, "w", encoding="utf-8") as f:
            for head in ["에이 클로트, 듣고… (14자)", "에이 클로트, 테스… (14자)", "클로드, 구이소… (9자)",
                         "감사합니다.… (6자)", "헤이 클로드… (6자)"]:
                f.write("11-21 22:00:00 ignore ← %s\n" % head)
        original = common.LOG_PATH
        common.LOG_PATH = log
        try:
            found = ui.wake_suggestions(CFG)
        finally:
            common.LOG_PATH = original
        self.assertEqual(found, [{"text": "에이 클로트", "count": 2}])


class LockTest(unittest.TestCase):
    def test_parallel_updates_are_not_lost(self):
        import tempfile
        from concurrent.futures import ThreadPoolExecutor
        folder = tempfile.mkdtemp()
        path = os.path.join(folder, "s.json")
        original = common.session_file
        common.session_file = lambda handle: path
        try:
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda i: common.update_session("x", **{"k%d" % i: i}), range(40)))
            self.assertEqual(len(common.read_json(path, {})), 40)
        finally:
            common.session_file = original


class FollowKeyboardTest(unittest.TestCase):
    def setUp(self):
        self.state = {"current": "t1"}
        common.listener_pid = lambda: 1
        common.load_state = lambda: dict(self.state)
        common.update_state = lambda **c: self.state.update(c)
        common.log = lambda *a: None
        common.load_config = lambda: dict(CFG, follow_keyboard=True)

    def submit(self, handle, prompt):
        os.environ["ORCA_TERMINAL_HANDLE"] = handle
        os.environ.pop("HANDSFREE_INTERNAL", None)
        sys.stdin = io.StringIO(json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": prompt}))
        speak.main()

    def test_typed_prompt_moves_current(self):
        self.submit("t2", "손으로 친 프롬프트")
        self.assertEqual(self.state["current"], "t2")

    def test_voice_prompt_does_not_move(self):
        self.state["last_sent"] = {"handle": "t3", "text": "음성으로 보낸 말", "at": time.time()}
        self.submit("t3", "음성으로 보낸 말")
        self.assertEqual(self.state["current"], "t1")

    def test_option_off(self):
        common.load_config = lambda: dict(CFG, follow_keyboard=False)
        self.submit("t2", "손으로 친 프롬프트")
        self.assertEqual(self.state["current"], "t1")


if __name__ == "__main__":
    unittest.main()
