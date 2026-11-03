"""A/B 채점 공용 도구. 에이전트가 고친 작업 폴더를 import해 숨긴 검사를 돌리고 JSON 한 줄을 낸다."""
import glob
import json
import os
import re
import subprocess
import sys
import traceback


def run(ws, checks):
    sys.path.insert(0, ws)
    results = []
    for name, kind, fn in checks:
        for mod in [m for m in list(sys.modules) if m == "orders" or m.startswith("orders.")]:
            del sys.modules[mod]
        try:
            fn()
            results.append({"name": name, "kind": kind, "pass": True})
        except BaseException as exc:  # noqa: BLE001 - sys.exit()·무한 재귀까지 그 검사만 실패로 기록한다
            detail = "".join(traceback.format_exception_only(type(exc), exc)).strip()
            results.append({"name": name, "kind": kind, "pass": False, "detail": detail[:300]})
    print(json.dumps({"checks": results}, ensure_ascii=False))


BASE_TESTS = 2  # fixture의 tests/test_service.py에 처음부터 있는 테스트 수


def tests_added(ws, word):
    """새 기능 테스트가 실제로 실행되는지 본다: 실행된 테스트 수가 늘었고, 그 이름(def test_...)에 word가 있다."""
    text = ""
    for path in glob.glob(os.path.join(ws, "tests", "*.py")):
        with open(path, encoding="utf-8") as f:
            text += f.read()
    assert re.search(r"def test_\w*" + re.escape(word), text), f"이름에 {word!r}가 든 테스트 함수 없음"
    proc = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-t", "."],
                          cwd=ws, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL,
                          env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    m = re.search(r"Ran (\d+) test", proc.stderr + proc.stdout)
    assert m and int(m.group(1)) > BASE_TESTS, f"실행된 테스트가 늘지 않음: {m.group(0) if m else '실행 실패'}"


def suite_passes(ws):
    proc = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-t", "."],
                          cwd=ws, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL,
                          env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    assert proc.returncode == 0, (proc.stdout + proc.stderr)[-300:]
