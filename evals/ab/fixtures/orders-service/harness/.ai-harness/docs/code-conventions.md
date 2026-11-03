# 코드 컨벤션

- 금액은 항상 `int`(원 단위)로 다룬다. `float` 결과를 저장하지 않는다.
- 도메인 오류는 `orders.errors.DomainError(code)`로 던진다.
- 주문 상태가 바뀌면 `audit.record(order_id, "<action>")`을 호출한다.
