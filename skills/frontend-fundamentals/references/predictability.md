# 예측 가능성 (Predictability) 상세 가이드

협업 동료들이 함수나 컴포넌트의 동작을 얼마나 예측할 수 있는지.

---

## A. 이름 겹치지 않게 관리하기

같은 이름의 함수/변수는 동일한 동작을 해야 한다.

**Bad:** 라이브러리의 `http`를 감싸면서 같은 이름 `http` 사용
```typescript
export const http = {
  async get(url: string) {
    const token = await fetchToken(); // 숨은 동작!
    return httpLibrary.get(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
  },
};
```

**Good:** 이름으로 차이를 드러내기
```typescript
export const httpService = {
  async getWithAuth(url: string) {
    const token = await fetchToken();
    return httpLibrary.get(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
  },
};
```

---

## B. 같은 종류의 함수는 반환 타입 통일하기

### 예시 1: API Hook

**Bad:** `useUser()`는 Query 객체 반환, `useServerTime()`은 data만 반환
**Good:** 모든 API Hook이 일관적으로 Query 객체를 반환

### 예시 2: 유효성 검사 함수

**Bad:** `checkIsNameValid()`는 boolean, `checkIsAgeValid()`는 객체 반환
- `if (checkIsAgeValid(age))` → 객체는 항상 truthy이므로 버그!

**Good:** 모두 `{ ok, reason? }` 객체를 반환

**고급 패턴 - Discriminated Union:**
```typescript
type ValidationResult = { ok: true } | { ok: false; reason: string };
```

---

## C. 숨은 로직 드러내기

함수의 이름, 파라미터, 반환 값에 드러나지 않는 숨은 로직은 예측 가능성을 해친다.

**Bad:**
```typescript
async function fetchBalance(): Promise<number> {
  const balance = await http.get<number>("...");
  logging.log("balance_fetched"); // 숨은 로직!
  return balance;
}
```

**Good:** 함수는 순수하게, 로깅은 호출부에서 명시적으로
```typescript
async function fetchBalance(): Promise<number> {
  return await http.get<number>("...");
}
// 호출부에서:
const balance = await fetchBalance();
logging.log("balance_fetched");
```

---

## D. 불리언 타입 변환

**Bad:** `if (!value)` → undefined 체크인지 빈문자열 체크인지 불명확
**Good:** `if (value === undefined)` → 의도가 명확

조건식에는 항상 불리언 값만 사용하거나, 의도를 명시적으로 드러내는 비교를 해야 한다.

---

## E. enum vs as const

TypeScript 생태계가 "타입 정보만 지우면 되는" 방향으로 이동 중이므로 `as const`를 선호한다.

- `enum`은 IIFE로 변환되어 tree-shaking 불가
- TypeScript 5.8의 `--erasableSyntaxOnly` 플래그가 이 방향을 뒷받침
- Node.js 23의 TypeScript 지원, TC39 proposal 모두 이 방향

```typescript
// Good
export const Status = {
  BANNED: 'Banned',
  INACTIVE: 'Inactive',
} as const;
export type Status = typeof Status[keyof typeof Status];
```
