---
name: component
description: 컴포넌트명을 입력받아 React 컴포넌트 보일러플레이트 생성 (tsx + test + stories)
team: frontend
trigger: "component|컴포넌트|boilerplate|보일러플레이트"
---

# React 컴포넌트 보일러플레이트 생성 Skill

## 사용법
/harness component [컴포넌트명] [선택: 디렉토리 경로]

예시: `/harness component ApplicantCard`
예시: `/harness component InterviewSlot src/features/interview/`

## 실행 내용

입력받은 컴포넌트명으로 ATS 프로젝트 표준에 맞는 3개 파일을 생성하라.

### ATS 도메인 컴포넌트 예시
- `ApplicantCard`: 지원자 요약 카드 (이름, 직무, 지원일, 현재 상태)
- `InterviewSlot`: 면접 시간 슬롯 (날짜/시간, 면접관, 장소, 온라인 여부)
- `EvaluationScore`: 면접 평가 점수 (항목별 점수, 총점, 등급, 코멘트)
- `JobPostingCard`: 채용공고 카드 (직무명, 부서, 마감일, 지원자 수)
- `ApplicationStatusStepper`: 지원 단계 표시기 (서류 → 1차 면접 → 최종 → 결과)
- `ResumeViewer`: 이력서 뷰어 (PDF 임베드, 페이지 네비게이션)

---

## 생성 파일 1: {ComponentName}.tsx

```tsx
import React from 'react';
import styles from './{ComponentName}.module.css';

export interface {ComponentName}Props {
  /** 컴포넌트의 주요 식별자 */
  id: string;
  /** 추가 CSS 클래스 */
  className?: string;
  /** 클릭 핸들러 */
  onClick?: () => void;
}

/**
 * {ComponentName} 컴포넌트
 * [ATS 도메인 내 역할 설명]
 */
export const {ComponentName}: React.FC<{ComponentName}Props> = ({
  id,
  className,
  onClick,
}) => {
  return (
    <div
      className={[styles.container, className].filter(Boolean).join(' ')}
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (e) => e.key === 'Enter' && onClick() : undefined}
      aria-label="{ComponentName}"
    >
      {/* 컴포넌트 내용 */}
    </div>
  );
};

export default {ComponentName};
```

## 생성 파일 2: {ComponentName}.test.tsx

```tsx
import { render, screen, fireEvent } from '@testing-library/react';
import { {ComponentName} } from './{ComponentName}';

describe('{ComponentName}', () => {
  const defaultProps: {ComponentName}Props = {
    id: 'test-id',
  };

  describe('렌더링', () => {
    it('기본 렌더링이 정상적으로 수행된다', () => {
      render(<{ComponentName} {...defaultProps} />);
      expect(screen.getByRole('...')).toBeInTheDocument();
    });

    it('추가 className이 적용된다', () => {
      const { container } = render(
        <{ComponentName} {...defaultProps} className="custom-class" />
      );
      expect(container.firstChild).toHaveClass('custom-class');
    });
  });

  describe('인터랙션', () => {
    it('onClick 핸들러가 호출된다', () => {
      const handleClick = jest.fn();
      render(<{ComponentName} {...defaultProps} onClick={handleClick} />);
      fireEvent.click(screen.getByRole('button'));
      expect(handleClick).toHaveBeenCalledTimes(1);
    });

    it('Enter 키로 onClick 핸들러가 호출된다', () => {
      const handleClick = jest.fn();
      render(<{ComponentName} {...defaultProps} onClick={handleClick} />);
      fireEvent.keyDown(screen.getByRole('button'), { key: 'Enter' });
      expect(handleClick).toHaveBeenCalledTimes(1);
    });
  });

  describe('접근성', () => {
    it('onClick이 있을 때 button role이 부여된다', () => {
      render(<{ComponentName} {...defaultProps} onClick={() => {}} />);
      expect(screen.getByRole('button')).toBeInTheDocument();
    });
  });
});
```

## 생성 파일 3: {ComponentName}.stories.tsx

```tsx
import type { Meta, StoryObj } from '@storybook/react';
import { {ComponentName} } from './{ComponentName}';

const meta: Meta<typeof {ComponentName}> = {
  title: 'ATS/{Category}/{ComponentName}',
  component: {ComponentName},
  parameters: {
    layout: 'centered',
    docs: {
      description: {
        component: '{ComponentName} 컴포넌트 - [ATS 도메인 설명]',
      },
    },
  },
  tags: ['autodocs'],
  argTypes: {
    onClick: { action: 'clicked' },
  },
};

export default meta;
type Story = StoryObj<typeof {ComponentName}>;

export const Default: Story = {
  args: {
    id: 'story-default',
  },
};

export const WithData: Story = {
  args: {
    id: 'story-with-data',
    // 실제 데이터가 있는 상태
  },
};

export const Loading: Story = {
  args: {
    id: 'story-loading',
    // 로딩 상태
  },
};

export const Error: Story = {
  args: {
    id: 'story-error',
    // 에러 상태
  },
};

export const Empty: Story = {
  args: {
    id: 'story-empty',
    // 빈 데이터 상태
  },
};
```
