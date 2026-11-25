"""매일 새벽 스케줄러가 부르는 배치 잡."""
from datetime import datetime


def purge_deleted(conn, now: datetime) -> int:
    """삭제 상태 문서의 본문을 비운다. 비운 건수를 돌려준다."""
    cur = conn.execute("UPDATE documents SET body = '' WHERE status = 'deleted' AND body != ''")
    return cur.rowcount
