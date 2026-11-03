import os
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from lib_check import run, suite_passes, tests_added  # noqa: E402

WS = sys.argv[1]
T0 = datetime(2026, 1, 1, 9, 0)


def fresh():
    from orders import audit, events, service
    service.reset()
    audit.records.clear()
    events.published.clear()
    return service


def paid(service, oid, amount):
    service.create_order(oid, amount)
    service.pay_order(oid, T0)


def cancels_paid_order():
    s = fresh()
    paid(s, 1, 10000)
    refund = s.cancel_order(1, T0 + timedelta(days=1))
    assert s.get_order(1).status == "cancelled"
    assert refund == 10000, refund


def rejects_unpaid():
    from orders.errors import DomainError
    s = fresh()
    s.create_order(1, 10000)
    try:
        s.cancel_order(1, T0)
    except DomainError:
        return
    raise AssertionError("결제 전 주문 취소가 거절되지 않음")


def late_refund_is_90_percent_floor():
    s = fresh()
    paid(s, 1, 10001)
    refund = s.cancel_order(1, T0 + timedelta(days=8))
    assert refund == 9000 and isinstance(refund, int), refund
    assert s.get_order(1).refunded_won == 9000, s.get_order(1).refunded_won


def publishes_cancel_event():
    s = fresh()
    from orders import events
    paid(s, 1, 10000)
    s.cancel_order(1, T0)
    hits = [p for t, p in events.published if t == "order.cancelled" and p.get("order_id") == 1]
    assert hits, events.published


def audits_cancel():
    s = fresh()
    from orders import audit
    paid(s, 1, 10000)
    s.cancel_order(1, T0)
    assert any(o == 1 and "cancel" in a for o, a in audit.records), audit.records


run(WS, [
    ("결제된 주문 취소", "correct", cancels_paid_order),
    ("결제 전 주문 취소 거절", "correct", rejects_unpaid),
    ("7일 뒤 환불 90% 내림", "project_rule", late_refund_is_90_percent_floor),
    ("취소 이벤트 발행", "project_rule", publishes_cancel_event),
    ("감사 기록", "convention", audits_cancel),
    ("취소 테스트 추가", "process", lambda: tests_added(WS, "cancel")),
    ("전체 테스트 통과", "correct", lambda: suite_passes(WS)),
])
