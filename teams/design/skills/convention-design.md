---
name: convention-design
description: Design 코드 컨벤션 — 디자인 토큰, 브레이크포인트, Figma 네이밍, 접근성
team: design
trigger: "컨벤션|convention|디자인 규칙|토큰"
---

# Design 코드 컨벤션

## 디자인 토큰
하드코딩된 색상/폰트/스페이싱 사용 금지. 반드시 토큰을 사용한다.

### 색상
```
$color-primary
$color-secondary
$color-danger
$color-warning
$color-success
```

### 스페이싱
```
$spacing-xs   — 4px
$spacing-sm   — 8px
$spacing-md   — 16px
$spacing-lg   — 24px
$spacing-xl   — 32px
```

### 타이포그래피
```
$font-body
$font-heading
$font-caption
```

## 반응형 브레이크포인트
모바일 퍼스트 원칙:

| 이름 | 너비 |
|------|------|
| Mobile | 360px |
| Tablet | 768px |
| Desktop | 1024px |
| Wide | 1440px |

## Figma 컴포넌트 네이밍
```
{Category}/{Component}/{Variant}
```

예시:
```
Form/Input/Default
Form/Input/Error
Navigation/Tab/Active
Data/Badge/Status-Pending
Data/Badge/Status-Passed
```

## 접근성 (WCAG 2.1 AA)
- 텍스트 명암비: 4.5:1 이상
- 키보드 네비게이션 지원 필수
- 포커스 인디케이터 명확히 표시
- 스크린 리더 호환 (`aria-label`, `role` 속성)

## ATS UI 주요 컴포넌트
- 지원자 목록: 필터/검색, 테이블 뷰, 상태 배지
- 칸반 보드: 채용 단계별 카드, 드래그앤드롭
- 면접 일정 캘린더: 월/주/일 뷰
- 평가표: 항목별 점수, 코멘트 입력

## 디자인 원칙
- 컴포넌트 단위 설계 (재사용성)
- 상태 변화(hover, focus, disabled, error) 모두 정의
- Empty State 디자인 필수
- 로딩/에러 상태 디자인 포함
