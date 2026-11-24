import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY,
    owner_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL,          -- active | archived | deleted
    updated_at TEXT NOT NULL,      -- 'YYYY-MM-DD HH:MM:SS'
    body TEXT NOT NULL             -- 문서 본문 원문 전체
)
"""


def connect(path: str = ":memory:") -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute(SCHEMA)
    return conn
