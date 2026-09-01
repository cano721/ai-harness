# 커뮤니티 합의 사항

Toss Frontend Fundamentals GitHub Discussions에서 실무 개발자들이 논의하여 합의한 패턴들.

---

## 조건부 렌더링: 상황별 구분

| 상황 | 추천 방식 |
|------|-----------|
| 단일 항목 + 단일 조건 | `&&` 또는 삼항 연산자 |
| 단일 항목 + 복수 조건 | `switch` |
| 복수 항목 + 복수 조건 | 전용 컴포넌트 |

**주의:** `<If />` 컴포넌트는 Short-circuiting이 보장되지 않아 TypeScript 타입 좁히기가 작동하지 않는다.

> 출처: [Discussion #4](https://github.com/toss/frontend-fundamentals/discussions/4) (26댓글)

---

## 전역 상태 도입: 상태 종류별 관리

depth가 아닌 **상태의 종류**로 판단한다:

| 상태 종류 | 관리 방법 |
|-----------|-----------|
| 서버 동기화 상태 | React Query/SWR (대부분 전역) |
| 인증/세션 | 브라우저 저장소 + 전역 |
| 라우팅 | URL (React Router 등) |
| 폼 | react-hook-form 등 (대부분 로컬) |
| 기타 클라이언트 | 상황에 따라 판단 |

ContextAPI는 "상태관리"가 아닌 **"의존성 주입"** 도구로 이해하는 것이 적절하다.

> 출처: [Discussion #5](https://github.com/toss/frontend-fundamentals/discussions/5) (18댓글)

---

## TypeScript: as const 선호

`enum` 대신 `as const`를 사용한다:
- `enum`은 IIFE 변환으로 tree-shaking 불가
- TS 생태계가 "타입 정보만 지우는" 방향으로 이동 중
- TypeScript 5.8 `--erasableSyntaxOnly` 플래그가 이를 뒷받침

> 출처: [Discussion #6](https://github.com/toss/frontend-fundamentals/discussions/6) (12댓글)

---

## 불리언 조건: 명시적 비교 선호

`if (!value)` 대신 `if (value === undefined)` 사용:
- 의도가 명확해야 예측 가능성이 높아진다
- 특정 값에 따라 로직이 달라져야 하면 반드시 명시적 비교

> 출처: [Discussion #21](https://github.com/toss/frontend-fundamentals/discussions/21)

---

## if문 return 스타일: 중괄호 포함

```tsx
// Good - Diff 최소화
if (condition) {
  return null;
}
```

코드 추가 시 중괄호가 없으면 불필요한 Diff가 발생한다. ESLint `curly` 규칙으로 자동화 가능.

> 출처: [Discussion #41](https://github.com/toss/frontend-fundamentals/discussions/41) (23댓글)

---

## queryKey 관리: 팩토리 패턴 또는 모듈화

중복 queryKey로 인한 캐싱 버그를 방지하기 위해:
- `@lukemorales/query-key-factory` 라이브러리 사용
- 또는 하나의 파일에 모든 queryKey를 모아 관리
- 도메인별 객체로 계층적 관리

> 출처: [Discussion #7](https://github.com/toss/frontend-fundamentals/discussions/7) (9댓글)

---

## 사이드이펙트 렌더링: Component 선호

채널톡 버튼처럼 간접적으로 UI를 렌더링하는 코드는 Hook보다 Component가 적합:
- 의도가 명확 ("컴포넌트를 렌더링하겠다")
- React DevTools에서 트리 위치 파악 가능
- 조건부 렌더링이 직관적: `{ condition && <ChannelTalkButton /> }`
- 독립적 렌더링 사이클이 필요하면 `react-nil` 사용

> 출처: [Discussion #35](https://github.com/toss/frontend-fundamentals/discussions/35)

---

## 다이얼로그 상태: overlay-kit

한 페이지에 다이얼로그 state가 많아지면 [overlay-kit](https://github.com/toss/overlay-kit)으로 선언적 관리.

> 출처: [Discussion #42](https://github.com/toss/frontend-fundamentals/discussions/42)

---

## Export 방식: named export 선호

- default export는 함수명 변경 시 import가 커버되지 않음
- named export는 선언되지 않은 것을 가져오면 오류 발생
- 번들러 tree-shaking에 유리
- 프레임워크가 강제하는 경우(Next.js page 등)만 예외 허용
- ESLint `import/no-default-export` 규칙 활용

> 출처: [Discussion #96](https://github.com/toss/frontend-fundamentals/discussions/96)
