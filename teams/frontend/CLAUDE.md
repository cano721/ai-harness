# Frontend Team - CLAUDE.md

## 도메인
ATS (Applicant Tracking System) 채용 관리 시스템

## 기술 스택

- React 18
- TypeScript
- Vite

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

## 컴포넌트 작성 규칙

- Props 타입은 `interface`로 정의 (`type` 키워드 사용 금지)
- 컴포넌트 파일명은 PascalCase

```tsx
interface ApplicantCardProps {
  applicantId: string;
  name: string;
  status: ApplicantStatus;
}

export function ApplicantCard({ applicantId, name, status }: ApplicantCardProps) {
  // ...
}
```

## 상태 관리

- **글로벌 상태**: Zustand
- **서버 상태**: React Query (캐싱, 동기화, 재시도)

```ts
// src/api/applicant.ts
export function useApplicants(jobPostingId: string) {
  return useQuery({
    queryKey: ['applicants', jobPostingId],
    queryFn: () => fetchApplicants(jobPostingId),
  });
}
```

## ATS 주요 페이지

| 페이지 | 경로 | 설명 |
|--------|------|------|
| JobPostingList | /jobs | 채용공고 목록 |
| ApplicantKanban | /jobs/:id/applicants | 지원자 칸반 보드 |
| InterviewCalendar | /interviews | 면접 일정 캘린더 |
| EvaluationForm | /interviews/:id/evaluate | 면접 평가표 |

## 성능 기준 (Core Web Vitals)

| 지표 | 목표 |
|------|------|
| LCP | < 2.5s |
| FID | < 100ms |
| CLS | < 0.1 |
| 초기 번들 (gzip) | < 300KB |

## 테스트

- 커버리지 80% 이상 유지
- 단위 테스트: Vitest + Testing Library
- 컴포넌트 테스트: 사용자 행동 기반 (구현 세부사항 테스트 지양)
