---
name: figma-to-code
description: Figma URL을 입력받아 React 컴포넌트 코드로 변환 (디자인 토큰 + 접근성 포함)
team: design
trigger: "figma-to-code|figma|피그마|컴포넌트 변환"
---

# Figma → React 컴포넌트 변환 Skill

## 사용법
/harness figma-to-code [Figma URL] [컴포넌트명]

예시: `/harness figma-to-code https://figma.com/file/xxx/... ApplicantCard`

## 실행 내용

주어진 Figma URL의 디자인을 분석하여 프로덕션 품질의 React 컴포넌트로 변환하라.

### 변환 규칙

**디자인 토큰 필수 사용**
- 색상: `var(--color-*)` 또는 프로젝트 토큰 파일 참조 (하드코딩 금지)
- 타이포그래피: `var(--font-size-*)`, `var(--font-weight-*)`
- 간격: `var(--spacing-*)` (px 직접 사용 금지)
- 반응형 브레이크포인트: `var(--breakpoint-sm/md/lg/xl)`
- 그림자: `var(--shadow-*)`

**접근성(a11y) 자동 추가**
- 시맨틱 HTML 태그 우선 사용 (`button`, `nav`, `main`, `section`, `article`)
- `aria-label`, `aria-describedby`, `aria-live` 등 ARIA 속성 추가
- 이미지에 의미 있는 `alt` 텍스트 작성 (장식용은 `alt=""`)
- 폼 요소에 `label` 연결 (`htmlFor` + `id`)
- 키보드 인터랙션 (`tabIndex`, `onKeyDown`) 추가
- 포커스 표시자 CSS 유지 (`:focus-visible`)
- 색상만으로 상태를 구분하지 않기 (아이콘/텍스트 병행)

---

## 출력 형식

### ComponentName.tsx
```tsx
import React from 'react';
import styles from './ComponentName.module.css';

interface ComponentNameProps {
  // props 정의
}

export const ComponentName: React.FC<ComponentNameProps> = ({
  // props destructuring
}) => {
  return (
    // JSX with semantic HTML and ARIA attributes
  );
};

export default ComponentName;
```

### ComponentName.module.css
```css
/* 디자인 토큰 기반 스타일 */
.container {
  color: var(--color-text-primary);
  padding: var(--spacing-md);
}
```

### 변환 노트
- Figma에서 발견된 디자인 이슈 또는 접근성 문제 목록
- 토큰이 없어 임시로 하드코딩한 값 목록 (토큰 추가 권장)
- 반응형 처리가 필요한 요소 목록

### ATS 도메인 컴포넌트 예시
- `ApplicantCard`: 지원자 카드 (이름, 직무, 지원일, 상태 배지)
- `InterviewSlot`: 면접 시간 슬롯 (날짜, 시간, 면접관, 위치)
- `EvaluationScore`: 평가 점수 (항목별 점수, 총점, 등급)
- `JobPostingBadge`: 채용공고 상태 배지 (진행중/마감/임시저장)
- `ApplicationStatusStepper`: 지원 단계 표시기 (서류/면접/최종)
