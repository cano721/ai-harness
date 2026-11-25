"""보관 정책. 요금제마다 보관 기준 기간이 다르고, 법적 보존 중인 소유자의 문서는 보관하지 않는다."""
from datetime import datetime, timedelta

DATETIME_FORMAT = "%Y-%m-%d %H:%M:%S"
PRO_OWNERS = {7, 8, 9}        # 유료 요금제 소유자 — 2년 동안 활성으로 둔다
LEGAL_HOLD_OWNERS = {13}      # 법적 보존 중 — 보관 금지


def retention_days(owner_id: int) -> int:
    return 730 if owner_id in PRO_OWNERS else 365


def is_stale(owner_id: int, updated_at: str, now: datetime) -> bool:
    """활성 문서를 보관할 때가 됐는지 판정한다."""
    if owner_id in LEGAL_HOLD_OWNERS:
        return False
    return now - datetime.strptime(updated_at, DATETIME_FORMAT) > timedelta(days=retention_days(owner_id))
