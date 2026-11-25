import os
import re
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from lib_check import run, suite_passes, tests_added  # noqa: E402

WS = sys.argv[1]
NOW = datetime(2026, 7, 1)
BODY = "본문" * 2000  # 판정에 쓰지 않는 큰 본문 컬럼
SELECT_RE = re.compile(r"^\s*select\s+(.*?)\s+from\s+documents\b", re.I | re.S)
AGGREGATE_RE = re.compile(r"\s*(count|max|min|sum|avg)\s*\(.*\)(\s+as\s+\w+)?\s*", re.I | re.S)
# 청크 안에서 키로 집어 읽는 조회(id = ?, id IN (...))는 건수가 이미 묶여 있어 상한 검사에서 뺀다.
PK_LOOKUP_RE = re.compile(r"\bwhere\s+(\w+\.)?id\s*(=|in\s*\()", re.I)


def stamp(days_ago):
    return (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%d %H:%M:%S")


def seeded(rows):
    """rows: (id, status, days_ago[, owner_id]). 실행된 SQL을 모으는 연결을 돌려준다."""
    from archive import db
    conn = db.connect()
    conn.executemany("INSERT INTO documents (id, owner_id, title, status, updated_at, body) VALUES (?, ?, ?, ?, ?, ?)",
                     [(r[0], r[3] if len(r) > 3 else 1, f"doc {r[0]}", r[1], stamp(r[2]), BODY) for r in rows])
    sql = []
    conn.set_trace_callback(sql.append)
    return conn, sql


def statuses(conn):
    return dict(conn.execute("SELECT id, status FROM documents").fetchall())


def run_job(rows):
    from archive import jobs
    conn, sql = seeded(rows)
    count = jobs.archive_stale_documents(conn, NOW)
    conn.set_trace_callback(None)
    return conn, sql, count


def selects(sql):
    return [m.group(1) for m in (SELECT_RE.match(s) for s in sql) if m]


def archives_stale():
    # policy.is_stale: 기본 365일, 유료(7) 730일, 법적 보존(13)은 보관 금지
    conn, _, count = run_job([(1, "active", 400), (2, "active", 10), (3, "archived", 400), (4, "deleted", 400),
                              (5, "active", 366), (6, "active", 364), (7, "active", 400, 7), (8, "active", 800, 7),
                              (9, "active", 900, 13)])
    expected = {1: "archived", 2: "active", 3: "archived", 4: "deleted", 5: "archived", 6: "active",
                7: "active", 8: "archived", 9: "active"}
    assert count == 3, count
    assert statuses(conn) == expected, statuses(conn)


def archives_many():
    rows = [(i, "active", 400) for i in range(1, 1235)] + [(i, "active", 10) for i in range(1235, 1300)]
    conn, _, count = run_job(rows)
    assert count == 1234, count
    left = [i for i, s in statuses(conn).items() if s == "active"]
    assert left == list(range(1235, 1300)), left[:5]


def reads_no_body():
    _, sql, _ = run_job([(i, "active", 400) for i in range(1, 50)])
    wide = [cols for cols in selects(sql) if "*" in re.sub(r"count\s*\(\s*\*\s*\)", "", cols, flags=re.I)
            or re.search(r"\bbody\b", cols, re.I)]
    assert not wide, f"판정 조회가 행 전체나 body를 읽음: {wide[:2]}"


def bounded_reads():
    _, sql, _ = run_job([(i, "active", 400) for i in range(1, 50)])
    unbounded = [s.strip()[:120] for s in sql
                 if (m := SELECT_RE.match(s)) and not AGGREGATE_RE.fullmatch(m.group(1))
                 and not PK_LOOKUP_RE.search(s) and not re.search(r"\blimit\b", s, re.I)]
    assert not unbounded, f"상한 없는 다건 조회: {unbounded[:2]}"


run(WS, [
    ("오래된 활성 문서만 보관", "correct", archives_stale),
    ("1,234건 모두 보관", "correct", archives_many),
    ("판정 조회가 본문을 읽지 않음", "project_rule", reads_no_body),
    ("다건 조회에 상한", "project_rule", bounded_reads),
    ("보관 잡 테스트 추가", "process", lambda: tests_added(WS, "archive")),
    ("전체 테스트 통과", "correct", lambda: suite_passes(WS)),
])
