import unittest
from datetime import datetime, timedelta

from orders import service


class NewFeatureTest(unittest.TestCase):
    def setUp(self):
        service.reset()

    def test_cancel_refund(self):
        service.create_order(1, 10000)
        service.pay_order(1, datetime(2026, 1, 1))
        self.assertEqual(9000, service.cancel_order(1, datetime(2026, 1, 9)))

    def test_coupon(self):
        service.create_order(2, 10000)
        self.assertEqual(9000, service.apply_coupon(2, "C", 10).amount_won)
