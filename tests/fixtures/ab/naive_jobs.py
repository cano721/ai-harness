"""매일 새벽 스케줄러가 부르는 배치 잡."""
from datetime import datetime

from . import policy, repository


def purge_deleted(conn, now: datetime) -> int:
    """삭제 상태 문서의 본문을 비운다. 비운 건수를 돌려준다."""
    cur = conn.execute("UPDATE documents SET body = '' WHERE status = 'deleted' AND body != ''")
    return cur.rowcount


def archive_stale_documents(conn, now: datetime) -> int:
    stale = [d.id for d in repository.find_documents_by_status(conn, "active")
             if policy.is_stale(d.owner_id, d.updated_at, now)]
    repository.update_status(conn, stale, "archived")
    return len(stale)
