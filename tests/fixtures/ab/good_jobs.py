"""매일 새벽 스케줄러가 부르는 배치 잡."""
from datetime import datetime

from . import policy, repository

CHUNK = 500


def purge_deleted(conn, now: datetime) -> int:
    """삭제 상태 문서의 본문을 비운다. 비운 건수를 돌려준다."""
    cur = conn.execute("UPDATE documents SET body = '' WHERE status = 'deleted' AND body != ''")
    return cur.rowcount


def archive_stale_documents(conn, now: datetime) -> int:
    archived, last_id = 0, 0
    while True:
        rows = conn.execute(
            "SELECT id, owner_id, updated_at FROM documents WHERE status = 'active' AND id > ? ORDER BY id LIMIT ?",
            (last_id, CHUNK)).fetchall()
        if not rows:
            return archived
        stale = [doc_id for doc_id, owner_id, updated_at in rows if policy.is_stale(owner_id, updated_at, now)]
        repository.update_status(conn, stale, "archived")
        archived += len(stale)
        last_id = rows[-1][0]
