# 주문 도메인 규칙

## 취소·환불

- 취소는 `paid` 상태에서만 된다. 그 밖의 상태는 `DomainError("INVALID_STATUS")`.
- 환불액: 결제 시각(`paid_at`)부터 **7일(168시간) 이내 취소면 전액**, 그 뒤면 **결제 금액의 90%를 원 단위 내림**(정수).
- 환불액은 `order.refunded_won`에 기록한다.
- 취소가 끝나면 `events.publish("order.cancelled", {"order_id": ..., "refunded_won": ...})`로 이벤트를 발행한다. 정산 시스템이 이 이벤트만 본다.

## 쿠폰

- 쿠폰은 `created` 상태(결제 전)에서만 적용된다. 그 밖은 `DomainError("INVALID_STATUS")`.
- 할인 후 금액 = `amount_won * (100 - percent) / 100`을 **원 단위 내림**(정수).
- 할인 후 금액이 **1,000원 미만이 되는 쿠폰은 거절**한다: `DomainError("MIN_AMOUNT")`. 주문은 바뀌지 않는다.
- 적용한 쿠폰 코드는 `order.coupons`에 추가한다.
