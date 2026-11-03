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
