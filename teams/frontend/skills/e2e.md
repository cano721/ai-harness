---
name: e2e
description: 시나리오 설명을 입력받아 ATS 도메인 Playwright E2E 테스트 생성
team: frontend
trigger: "e2e|playwright|E2E|시나리오 테스트|end-to-end"
---

# Playwright E2E 테스트 생성 Skill

## 사용법
/harness e2e [시나리오 설명]

예시: `/harness e2e "채용담당자가 채용공고를 등록하는 시나리오"`
예시: `/harness e2e "지원자가 이력서를 첨부하여 지원서를 제출하는 시나리오"`

## 실행 내용

입력받은 시나리오를 분석하여 ATS 도메인에 맞는 완전한 Playwright E2E 테스트를 생성하라.

### ATS 핵심 시나리오 목록

**채용공고 관리**
- 채용담당자가 새 채용공고를 등록하고 게시한다
- 채용담당자가 채용공고를 수정하고 저장한다
- 채용담당자가 채용공고를 마감 처리한다

**지원서 관리**
- 지원자가 이력서를 첨부하여 지원서를 제출한다
- 지원자가 지원 현황을 조회한다
- 채용담당자가 지원서를 스크리닝하고 상태를 변경한다

**면접 일정 관리**
- 채용담당자가 면접 일정을 등록하고 면접관에게 알림을 보낸다
- 면접관이 면접 일정을 확인하고 참석 여부를 응답한다
- 지원자가 면접 일정 초대를 확인한다

**평가 관리**
- 면접관이 면접 후 평가표를 작성하고 제출한다
- HR관리자가 평가 결과를 취합하여 최종 결과를 결정한다

---

## 출력 형식: {scenario-name}.spec.ts

```typescript
import { test, expect, Page } from '@playwright/test';

// 테스트 데이터
const testData = {
  recruiter: {
    email: 'recruiter@company.com',
    password: 'Test1234!',
  },
  applicant: {
    email: 'applicant@email.com',
    password: 'Test1234!',
    name: '김지원',
  },
  jobPosting: {
    title: '시니어 프론트엔드 개발자',
    department: '개발팀',
    closingDate: '2024-12-31',
  },
};

// 공통 헬퍼
async function login(page: Page, email: string, password: string) {
  await page.goto('/login');
  await page.getByLabel('이메일').fill(email);
  await page.getByLabel('비밀번호').fill(password);
  await page.getByRole('button', { name: '로그인' }).click();
  await expect(page).toHaveURL('/dashboard');
}

test.describe('[시나리오명] - ATS [도메인]', () => {
  test.beforeEach(async ({ page }) => {
    // 공통 사전 조건 설정
    await login(page, testData.recruiter.email, testData.recruiter.password);
  });

  test('정상 케이스: [기대 동작]', async ({ page }) => {
    // Given: 사전 조건
    await page.goto('/job-postings/new');

    // When: 사용자 행동
    await page.getByLabel('직무명').fill(testData.jobPosting.title);
    await page.getByLabel('부서').selectOption(testData.jobPosting.department);
    await page.getByLabel('마감일').fill(testData.jobPosting.closingDate);
    await page.getByRole('button', { name: '저장' }).click();

    // Then: 기대 결과
    await expect(page.getByRole('alert')).toHaveText('채용공고가 저장되었습니다.');
    await expect(page).toHaveURL(/\/job-postings\/\d+/);
  });

  test('예외 케이스: 필수 항목 미입력 시 유효성 검사 오류', async ({ page }) => {
    await page.goto('/job-postings/new');
    await page.getByRole('button', { name: '저장' }).click();

    await expect(page.getByText('직무명을 입력해주세요.')).toBeVisible();
  });

  test('경계 케이스: 마감일이 오늘보다 이전인 경우', async ({ page }) => {
    await page.goto('/job-postings/new');
    await page.getByLabel('직무명').fill(testData.jobPosting.title);
    await page.getByLabel('마감일').fill('2020-01-01');
    await page.getByRole('button', { name: '저장' }).click();

    await expect(page.getByText('마감일은 오늘 이후여야 합니다.')).toBeVisible();
  });
});
```

### 생성 기준
- Page Object Model(POM) 패턴 적용 여부는 테스트 규모에 따라 결정
- `getByRole`, `getByLabel`, `getByText` 우선 사용 (CSS 셀렉터 최소화)
- 네트워크 요청 모킹이 필요한 경우 `page.route()` 사용
- 각 테스트는 독립적으로 실행 가능해야 함
- 테스트 데이터는 `testData` 객체로 중앙 관리
