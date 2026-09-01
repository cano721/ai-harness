# 응집도 (Cohesion) 상세 가이드

수정되어야 할 코드가 항상 같이 수정되는지. 응집도와 가독성은 상충할 수 있다.

---

## A. 함께 수정되는 파일을 같은 디렉토리에 두기

**Bad (종류별 분류):**
```
└─ src
   ├─ components
   ├─ constants
   ├─ containers
   ├─ hooks
   └─ utils
```
문제: 파일 간 의존 관계 파악 어려움, 기능 삭제 시 누락 코드 발생

**Good (도메인별 분류):**
```
└─ src
   ├─ components     // 전체 프로젝트 공통
   ├─ hooks
   ├─ utils
   └─ domains
      ├─ Domain1     // Domain1에서만 사용
      │  ├─ components
      │  ├─ hooks
      │  └─ utils
      └─ Domain2
         ├─ components
         └─ hooks
```

**장점:**
- `../../../Domain2/hooks/useFoo` 같은 잘못된 참조를 즉시 인지
- 기능 삭제 시 디렉토리 전체를 삭제하면 깔끔
- 사용되지 않는 코드 방지

---

## B. 매직 넘버 없애기

매직 넘버는 함께 수정되어야 할 코드 중 한쪽만 수정되는 문제를 일으킨다.

**Bad:** 애니메이션 시간을 바꿨을 때 `delay(300)`도 바꿔야 하지만 놓침
**Good:** `const ANIMATION_DELAY_MS = 300;` 상수로 선언하여 한 곳만 수정

---

## C. 폼의 응집도 생각하기

### 필드 단위 응집도

각 필드의 `register`에 validation을 인라인으로 작성.

```tsx
<input
  {...register("email", {
    validate: (value) => {
      if (isEmptyStringOrNil(value)) return "이메일을 입력해주세요.";
      if (!/^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i.test(value))
        return "유효한 이메일 주소를 입력해주세요.";
      return "";
    },
  })}
/>
```

**적합한 경우:** 독립적 검증, 재사용 필요

### 폼 전체 단위 응집도

Zod 스키마로 검증 로직을 한 곳에 모은다.

```tsx
const schema = z.object({
  name: z.string().min(1, "이름을 입력해주세요."),
  email: z.string().min(1, "이메일을 입력해주세요.")
    .email("유효한 이메일 주소를 입력해주세요."),
});
```

**적합한 경우:** 밀접한 필드(결제/배송 정보), Wizard Form, 필드 간 의존성
