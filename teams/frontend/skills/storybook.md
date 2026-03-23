---
name: storybook
description: 기존 컴포넌트를 입력받아 Default/WithData/Loading/Error/Empty 상태 포함 Storybook 스토리 자동 생성
team: frontend
trigger: "storybook|스토리북|stories|story"
---

# Storybook 스토리 자동 생성 Skill

## 사용법
/harness storybook [컴포넌트 파일 경로]

예시: `/harness storybook src/components/ApplicantCard/ApplicantCard.tsx`
예시: `/harness storybook src/features/interview/InterviewSlot.tsx`

## 실행 내용

지정된 컴포넌트 파일을 분석하여 props 타입과 구조를 파악하고, 완전한 Storybook 스토리 파일을 생성하라.

### 분석 단계
1. 컴포넌트 파일을 읽어 `Props` 인터페이스/타입을 파악하라.
2. 컴포넌트가 받는 모든 props와 그 타입, 기본값을 목록화하라.
3. 컴포넌트가 사용하는 상태(loading, error, empty 등)를 파악하라.
4. ATS 도메인 컨텍스트에 맞는 현실적인 목 데이터를 준비하라.

### ATS 도메인 목 데이터 예시
```typescript
// 지원자 목 데이터
const mockApplicant = {
  id: 'app-001',
  name: '김지원',
  email: 'jiwon.kim@email.com',
  phone: '010-1234-5678',
  appliedAt: '2024-01-15T09:00:00Z',
  status: 'INTERVIEW_SCHEDULED',
  resumeUrl: 'https://example.com/resume.pdf',
};

// 채용공고 목 데이터
const mockJobPosting = {
  id: 'job-001',
  title: '시니어 프론트엔드 개발자',
  department: '개발팀',
  location: '서울 강남구',
  closingDate: '2024-02-28',
  applicantCount: 42,
  status: 'ACTIVE',
};

// 면접 목 데이터
const mockInterview = {
  id: 'int-001',
  scheduledAt: '2024-01-20T14:00:00Z',
  duration: 60,
  type: 'TECHNICAL',
  location: '본사 3층 회의실 A',
  interviewers: ['이팀장', '박수석'],
  isOnline: false,
};
```

---

## 출력 형식: {ComponentName}.stories.tsx

```tsx
import type { Meta, StoryObj } from '@storybook/react';
import { within, userEvent } from '@storybook/testing-library';
import { expect } from '@storybook/jest';
import { {ComponentName} } from './{ComponentName}';

const meta: Meta<typeof {ComponentName}> = {
  title: 'ATS/{Category}/{ComponentName}',
  component: {ComponentName},
  parameters: {
    layout: 'centered',
    docs: {
      description: {
        component: `
**{ComponentName}** 컴포넌트입니다.

[컴포넌트의 ATS 도메인 역할 설명]
        `,
      },
    },
  },
  tags: ['autodocs'],
  argTypes: {
    // props별 controls 설정
  },
};

export default meta;
type Story = StoryObj<typeof {ComponentName}>;

/** 기본 상태: 가장 일반적인 사용 케이스 */
export const Default: Story = {
  args: {
    // 기본 props
  },
};

/** 데이터 있는 상태: 실제 ATS 데이터가 채워진 상태 */
export const WithData: Story = {
  args: {
    // 현실적인 ATS 도메인 목 데이터
  },
};

/** 로딩 상태: 데이터를 불러오는 중인 상태 */
export const Loading: Story = {
  args: {
    isLoading: true,
  },
};

/** 에러 상태: 데이터 로드 실패 또는 오류 발생 상태 */
export const Error: Story = {
  args: {
    error: '데이터를 불러오는 중 오류가 발생했습니다.',
  },
};

/** 빈 상태: 데이터가 없는 경우 */
export const Empty: Story = {
  args: {
    // 빈 데이터 상태
    data: [],
  },
};

/** 인터랙션 테스트: 사용자 행동 시뮬레이션 */
export const InteractionTest: Story = {
  args: {
    // 인터랙션 테스트용 props
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    // 인터랙션 시뮬레이션 및 결과 검증
    const element = canvas.getByRole('button');
    await userEvent.click(element);
    await expect(element).toHaveAttribute('aria-pressed', 'true');
  },
};
```

### 스토리 생성 체크리스트
- [ ] 모든 필수 props가 Default 스토리에 포함되었는가
- [ ] ATS 도메인에 맞는 현실적인 목 데이터를 사용했는가
- [ ] Loading, Error, Empty 상태가 컴포넌트 구현에 맞게 작성되었는가
- [ ] argTypes에 모든 props 타입과 설명이 정의되었는가
- [ ] JSDoc 주석으로 각 스토리의 목적이 설명되었는가
