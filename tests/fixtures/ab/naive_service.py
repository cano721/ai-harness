from datetime import datetime

from . import audit
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
    order.status = "cancelled"
    order.refunded_won = order.amount_won
    return order.amount_won


def apply_coupon(order_id: int, code: str, percent: int) -> Order:
    order = get_order(order_id)
    order.amount_won = round(order.amount_won * (1 - percent / 100))
    return order
