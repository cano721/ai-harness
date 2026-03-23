---
name: convention-frontend
description: Frontend 코드 컨벤션 — 컴포넌트 구조, 상태 관리, API 호출, 성능 기준, 예시 코드
team: frontend
trigger: "컨벤션|convention|코드 규칙|코딩 규칙"
---

# Frontend 코드 컨벤션

## 기술 스택
- React 18 + TypeScript + Vite

## 디렉토리 구조
```
src/
  components/
    {feature}/          # 기능별 컴포넌트
      {Component}.tsx
    common/             # 공통 컴포넌트
  api/
    {domain}.ts         # API 호출 + React Query hook
  stores/               # Zustand 글로벌 상태
  pages/
```

## 컴포넌트 규칙
- Props 타입은 `interface`로 정의 (`type` 키워드 사용 금지)
- 파일명은 PascalCase
- moment.js 금지 → dayjs 사용
- lodash 전체 import 금지 → 개별 import (`import debounce from 'lodash/debounce'`)

## 상태 관리
- 글로벌 상태: Zustand
- 서버 상태: React Query (캐싱, 동기화, 재시도)

## 성능 기준 (Core Web Vitals)
| 지표 | 목표 |
|------|------|
| LCP | < 2.5s |
| FID | < 100ms |
| CLS | < 0.1 |
| 초기 번들 (gzip) | < 300KB |

## 테스트
- 커버리지 80% 이상
- Vitest + Testing Library
- 사용자 행동 기반 테스트 (구현 세부사항 테스트 지양)

## 예시: 컴포넌트 + Hook + 테스트 보일러플레이트

### 컴포넌트
```tsx
interface ApplicantCardProps {
  applicantId: string;
  name: string;
  status: ApplicantStatus;
}

export function ApplicantCard({ applicantId, name, status }: ApplicantCardProps) {
  return (
    <div className="applicant-card">
      <span>{name}</span>
      <StatusBadge status={status} />
    </div>
  );
}
```

### React Query Hook
```ts
// src/api/applicant.ts
export function useApplicants(jobPostingId: string) {
  return useQuery({
    queryKey: ['applicants', jobPostingId],
    queryFn: () => fetchApplicants(jobPostingId),
  });
}
```

### 테스트
```tsx
import { render, screen } from '@testing-library/react';
import { ApplicantCard } from './ApplicantCard';

test('지원자 이름을 표시한다', () => {
  render(<ApplicantCard applicantId="1" name="홍길동" status="DOCUMENT_REVIEW" />);
  expect(screen.getByText('홍길동')).toBeInTheDocument();
});
```
