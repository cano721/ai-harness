from datetime import datetime

from . import audit, events
from .errors import DomainError
from .models import Order

_orders = {}


def create_order(order_id: int, amount_won: int) -> Order:
    if amount_won <= 0:
        raise DomainError("INVALID_AMOUNT")
    order = Order(id=order_id, amount_won=amount_won)
    _orders[order_id] = order
    audit.record(order_id, "created")
    return order


def get_order(order_id: int) -> Order:
    order = _orders.get(order_id)
    if order is None:
        raise DomainError("ORDER_NOT_FOUND")
    return order


def pay_order(order_id: int, now: datetime) -> Order:
    order = get_order(order_id)
    if order.status != "created":
        raise DomainError("INVALID_STATUS")
    order.status = "paid"
    order.paid_at = now
    audit.record(order_id, "paid")
    return order


def reset():
    _orders.clear()


def cancel_order(order_id: int, now: datetime) -> int:
    order = get_order(order_id)
    if order.status != "paid":
        raise DomainError("INVALID_STATUS")
    if (now - order.paid_at).total_seconds() <= 7 * 24 * 3600:
        refund = order.amount_won
    else:
        refund = order.amount_won * 90 // 100
    order.status = "cancelled"
    order.refunded_won = refund
    audit.record(order_id, "cancelled")
    events.publish("order.cancelled", {"order_id": order_id, "refunded_won": refund})
    return refund


def apply_coupon(order_id: int, code: str, percent: int) -> Order:
    order = get_order(order_id)
    if order.status != "created":
        raise DomainError("INVALID_STATUS")
    discounted = order.amount_won * (100 - percent) // 100
    if discounted < 1000:
        raise DomainError("MIN_AMOUNT")
    order.amount_won = discounted
    order.coupons.append(code)
    audit.record(order_id, "coupon_applied")
    return order
