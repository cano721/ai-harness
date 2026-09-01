# 가독성 (Readability) 상세 가이드

코드가 읽기 쉬운 정도. 코드 변경을 위해서는 먼저 동작을 이해할 수 있어야 한다.

---

## A. 맥락 줄이기

### A-1. 같이 실행되지 않는 코드 분리하기

동시에 실행되지 않는 코드가 하나의 컴포넌트에 있으면 동작을 한눈에 파악하기 어렵다.

**Bad:**
```tsx
function SubmitButton() {
  const isViewer = useRole() === "viewer";
  useEffect(() => {
    if (isViewer) { return; }
    showButtonAnimation();
  }, [isViewer]);
  return isViewer ? (
    <TextButton disabled>Submit</TextButton>
  ) : (
    <Button type="submit">Submit</Button>
  );
}
```

**Good:** 각 권한 상태를 별도 컴포넌트로 분리
```tsx
function SubmitButton() {
  const isViewer = useRole() === "viewer";
  return isViewer ? <ViewerSubmitButton /> : <AdminSubmitButton />;
}
function ViewerSubmitButton() {
  return <TextButton disabled>Submit</TextButton>;
}
function AdminSubmitButton() {
  useEffect(() => { showButtonAnimation(); }, []);
  return <Button type="submit">Submit</Button>;
}
```

### A-2. 구현 상세 추상화하기

한 사람이 동시에 고려할 수 있는 맥락의 수는 약 6~7개. 불필요한 상세를 감춰라.

**패턴:** Wrapper 컴포넌트, HOC로 인증/권한 같은 관심사를 분리
```tsx
function App() {
  return (
    <AuthGuard>
      <LoginStartPage />
    </AuthGuard>
  );
}
```

**패턴:** 복잡한 핸들러를 별도 컴포넌트로 분리 (FriendInvitation → InviteButton)

### A-3. 로직 종류에 따라 합쳐진 함수 쪼개기

**Bad:** `usePageState()` - 모든 쿼리 파라미터를 하나의 Hook에서 관리
- 책임이 무제한으로 증가
- 사용 컴포넌트가 모든 파라미터 변경에 리렌더링

**Good:** 각 파라미터별 별도 Hook
```typescript
export function useCardIdQueryParam() {
  const [cardId, _setCardId] = useQueryParam("cardId", NumberParam);
  const setCardId = useCallback((cardId: number) => {
    _setCardId({ cardId }, "replaceIn");
  }, []);
  return [cardId ?? undefined, setCardId] as const;
}
```

---

## B. 이름 붙이기

### B-1. 복잡한 조건에 이름 붙이기

**Bad:**
```typescript
const result = products.filter((product) =>
  product.categories.some((category) =>
    category.id === targetCategory.id &&
    product.prices.some((price) => price >= minPrice && price <= maxPrice)
  )
);
```

**Good:**
```typescript
const matchedProducts = products.filter((product) => {
  return product.categories.some((category) => {
    const isSameCategory = category.id === targetCategory.id;
    const isPriceInRange = product.prices.some(
      (price) => price >= minPrice && price <= maxPrice
    );
    return isSameCategory && isPriceInRange;
  });
});
```

**이름을 붙이면 좋을 때:** 복잡한 로직이 여러 줄에 걸칠 때, 재사용 필요 시, 테스트 필요 시

### B-2. 매직 넘버에 이름 붙이기

**Bad:** `await delay(300);` → 300이 무엇인지 불명확
**Good:** `const ANIMATION_DELAY_MS = 300; await delay(ANIMATION_DELAY_MS);`

---

## C. 위에서 아래로 읽히게 하기

### C-1. 시점 이동 줄이기

코드를 위아래로 왕복하거나 여러 파일을 넘나드는 것이 "시점 이동". 시점 이동이 적을수록 좋다.

**Bad:** `policy.canInvite` → `getPolicyByRole()` → `POLICY_SET` (3번의 시점 이동)

**Good (방법 A):** switch로 조건을 펼쳐서 드러내기
**Good (방법 B):** 인라인 객체로 시점 이동 제거
```tsx
const policy = {
  admin: { canInvite: true, canView: true },
  viewer: { canInvite: false, canView: true },
}[user.role];
```

### C-2. 삼항 연산자 단순하게 하기

**Bad:** `const status = A && B ? "BOTH" : A || B ? (A ? "A" : "B") : "NONE";`
**Good:** IIFE + if문으로 순차적으로 풀기

### C-3. 비교 순서 왼쪽에서 오른쪽으로

**Bad:** `if (score >= 80 && score <= 100)`
**Good:** `if (80 <= score && score <= 100)` (수학 표기법처럼)
