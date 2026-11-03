from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class Order:
    id: int
    amount_won: int
    status: str = "created"  # created | paid | cancelled | shipped
    paid_at: Optional[datetime] = None
    refunded_won: int = 0
    coupons: list = field(default_factory=list)
