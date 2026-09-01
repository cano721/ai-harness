# 결합도 (Coupling) 상세 가이드

코드 수정 시 영향범위. 영향범위가 적으면 변경이 수월하다.

---

## A. 책임을 하나씩 관리하기

**Bad:** `usePageState()` - 모든 쿼리 파라미터를 한 Hook에서 관리
- 새 파라미터가 추가되면 무의식적으로 이 Hook에 추가됨
- 모든 사용 컴포넌트가 모든 파라미터 변경에 리렌더링

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

## B. 중복 코드 허용하기

여러 페이지에서 반복되는 코드를 무조건 공통화하면 결합도가 높아진다.

**공통화 전 체크리스트:**
- 로깅하는 값이 달라질 가능성은?
- 어떤 페이지에서는 화면을 닫을 필요가 없을 가능성은?
- 바텀시트 텍스트/이미지를 다르게 해야 할 가능성은?

**판단 기준:**
- 동작이 동일하고 **향후에도 그럴 예정** → 공통화
- 동작이 달라질 여지가 있음 → **중복 코드 허용**

---

## C. Props Drilling 제거하기

Props Drilling은 부모-자식 간 결합도를 높인다. prop 이름 변경 시 모든 중간 컴포넌트를 수정해야 한다.

### 해결 순서 (권장)

**1단계: props가 역할을 명확히 표현하는지 확인**
- 단순히 전달만 하는 prop은 문제의 신호

**2단계: children (Composition 패턴)**
```tsx
function ItemEditModal({ open, items, recommendedItems, onConfirm, onClose }) {
  const [keyword, setKeyword] = useState("");
  return (
    <Modal open={open} onClose={onClose}>
      <ItemEditBody keyword={keyword} onKeywordChange={setKeyword} onClose={onClose}>
        <ItemEditList
          keyword={keyword}
          items={items}
          recommendedItems={recommendedItems}
          onConfirm={onConfirm}
        />
      </ItemEditBody>
    </Modal>
  );
}
```

**3단계: Context API (마지막 수단)**
```tsx
function ItemEditList({ keyword, onConfirm }) {
  const { items, recommendedItems } = useItemEditModalContext();
  // ...
}
```
