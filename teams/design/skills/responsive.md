---
name: responsive
description: 컴포넌트를 입력받아 반응형 브레이크포인트(360/768/1024/1440) 검증
team: design
trigger: "responsive|반응형|브레이크포인트|breakpoint|모바일"
---

# 반응형 검증 Skill

## 사용법
/harness responsive [파일 경로 또는 컴포넌트명]

예시: `/harness responsive src/components/JobPostingList.tsx`
예시: `/harness responsive src/pages/ApplicantDetail/`

## 실행 내용

지정된 컴포넌트를 ATS 프로젝트의 표준 브레이크포인트 기준으로 반응형 구현 상태를 검증하고 개선안을 제시하라.

### 브레이크포인트 정의
| 구분 | 너비 | 대상 디바이스 |
|------|------|-------------|
| Mobile S | 360px | 소형 스마트폰 |
| Tablet | 768px | 태블릿, 대형 스마트폰 |
| Desktop | 1024px | 노트북, 소형 모니터 |
| Wide | 1440px | 대형 모니터, 와이드스크린 |

### 검사 항목

**1. 레이아웃 깨짐 (Layout Break)**
- 각 브레이크포인트에서 요소 overflow 발생 여부
- Grid/Flexbox 레이아웃 의도된 변환 여부
- 고정 너비(`px`) 사용으로 인한 레이아웃 깨짐 확인
- `min-width`, `max-width` 적절한 사용 여부

**2. 오버플로우 (Overflow)**
- `overflow: hidden` 숨겨진 콘텐츠 존재 여부
- 텍스트 잘림(`text-overflow: ellipsis`) 적절성
- 가로 스크롤 발생 여부
- 이미지 오버플로우 (`max-width: 100%` 미적용)

**3. 터치 타겟 크기 (Touch Target)**
- 모바일(360px, 768px)에서 인터랙티브 요소 최소 크기 44x44px 준수
- 버튼, 링크, 체크박스, 라디오 버튼 터치 타겟 확인
- 인접한 터치 타겟 간 최소 8px 간격 확인
- `padding`을 활용한 터치 영역 확장 여부

**4. 타이포그래피 가독성**
- 모바일에서 최소 폰트 크기 14px 이상
- 줄간격(line-height) 1.4 이상
- 한 줄 텍스트 최대 너비 (75자 이하 권장)

**5. 이미지 및 미디어**
- `srcSet` 또는 `<picture>` 태그로 반응형 이미지 제공 여부
- 모바일에서 불필요한 큰 이미지 로드 여부
- 비율 유지(`aspect-ratio`) 설정 여부

---

## 출력 형식

### 브레이크포인트별 검사 결과
| 검사 항목 | 360px | 768px | 1024px | 1440px |
|----------|-------|-------|--------|--------|
| 레이아웃 | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| 오버플로우 | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| 터치 타겟 | ✅/❌ | ✅/❌ | N/A | N/A |
| 타이포그래피 | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| 이미지 | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |

### 문제 상세 및 수정 코드
각 문제에 대해 현재 코드와 수정 코드를 함께 제공하라.

### CSS 미디어 쿼리 개선안
프로젝트 표준 브레이크포인트에 맞는 미디어 쿼리 코드를 제안하라.

```css
/* ATS 표준 브레이크포인트 */
@media (max-width: 767px) { /* Mobile */ }
@media (min-width: 768px) and (max-width: 1023px) { /* Tablet */ }
@media (min-width: 1024px) and (max-width: 1439px) { /* Desktop */ }
@media (min-width: 1440px) { /* Wide */ }
```
