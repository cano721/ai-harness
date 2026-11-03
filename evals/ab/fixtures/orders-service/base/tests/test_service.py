import unittest
from datetime import datetime

from orders import service
from orders.errors import DomainError


class ServiceTest(unittest.TestCase):
    def setUp(self):
        service.reset()

    def test_pay_order(self):
        service.create_order(1, 10000)
        order = service.pay_order(1, datetime(2026, 1, 1))
        self.assertEqual("paid", order.status)

    def test_pay_twice_fails(self):
        service.create_order(1, 10000)
        service.pay_order(1, datetime(2026, 1, 1))
        with self.assertRaises(DomainError):
            service.pay_order(1, datetime(2026, 1, 2))


if __name__ == "__main__":
    unittest.main()
