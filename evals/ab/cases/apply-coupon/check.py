import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from lib_check import run, suite_passes, tests_added  # noqa: E402

WS = sys.argv[1]


def fresh():
    from orders import audit, service
    service.reset()
    audit.records.clear()
    return service


def expect_domain_error(fn):
    from orders.errors import DomainError
    try:
        fn()
    except DomainError:
        return
    raise AssertionError("DomainError가 나지 않음")


def applies_discount():
    s = fresh()
    s.create_order(1, 10000)
    order = s.apply_coupon(1, "WELCOME10", 10)
    assert order.amount_won == 9000, order.amount_won


def rejects_after_payment():
    s = fresh()
    s.create_order(1, 10000)
    s.pay_order(1, datetime(2026, 1, 1))
    expect_domain_error(lambda: s.apply_coupon(1, "LATE", 10))


def floors_to_int():
    s = fresh()
    s.create_order(1, 10001)
    order = s.apply_coupon(1, "P15", 15)
    # 8500.85: 내림이면 8500, 반올림이면 8501
    assert order.amount_won == 8500 and isinstance(order.amount_won, int), order.amount_won


def rejects_below_minimum():
    s = fresh()
    s.create_order(1, 1500)
    expect_domain_error(lambda: s.apply_coupon(1, "HALF", 50))
    assert s.get_order(1).amount_won == 1500, s.get_order(1).amount_won


def records_coupon():
    s = fresh()
    s.create_order(1, 10000)
    s.apply_coupon(1, "WELCOME10", 10)
    assert "WELCOME10" in s.get_order(1).coupons, s.get_order(1).coupons


def audits_coupon():
    s = fresh()
    from orders import audit
    s.create_order(1, 10000)
    s.apply_coupon(1, "WELCOME10", 10)
    assert any(o == 1 and a not in ("created", "paid") for o, a in audit.records), audit.records


run(WS, [
    ("쿠폰 할인 적용", "correct", applies_discount),
    ("원 단위 내림·정수", "project_rule", floors_to_int),
    ("결제 후 쿠폰 거절", "project_rule", rejects_after_payment),
    ("1,000원 미만 거절", "project_rule", rejects_below_minimum),
    ("쿠폰 코드 기록", "project_rule", records_coupon),
    ("감사 기록", "convention", audits_coupon),
    ("쿠폰 테스트 추가", "process", lambda: tests_added(WS, "coupon")),
    ("전체 테스트 통과", "correct", lambda: suite_passes(WS)),
])
