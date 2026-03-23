import { describe, it, expect } from 'vitest';
import {
  createHandoff,
  advancePhase,
  getNextPhase,
  validateArtifacts,
} from '../../src/engine/workflow-engine.js';
import { WorkflowPhase } from '../../src/types/workflow.js';

describe('createHandoff', () => {
  it('새 핸드오프를 생성한다', () => {
    const data = createHandoff('PROJ-1', 'planning', { prd_url: 'https://example.com/prd' });
    expect(data.issue_key).toBe('PROJ-1');
    expect(data.current_phase).toBe('planning');
    expect(data.history).toHaveLength(1);
    expect(data.history[0].phase).toBe('planning');
    expect(data.history[0].artifacts.prd_url).toBe('https://example.com/prd');
  });

  it('history의 completed_at이 ISO 문자열이다', () => {
    const data = createHandoff('PROJ-2', 'design', { figma_url: 'https://figma.com/file/abc' });
    expect(data.history[0].completed_at).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });
});

describe('advancePhase', () => {
  it('다음 단계로 이동하고 history에 현재 단계를 추가한다', () => {
    const data = createHandoff('PROJ-3', 'planning', { prd_url: 'https://example.com/prd' });
    const advanced = advancePhase(data, { figma_url: 'https://figma.com/file/abc' });
    expect(advanced.current_phase).toBe('design');
    expect(advanced.history).toHaveLength(2);
    expect(advanced.history[1].phase).toBe('planning');
    expect(advanced.history[1].artifacts.figma_url).toBe('https://figma.com/file/abc');
  });

  it('마지막 단계(deploy)에서 advancePhase 호출 시 에러를 던진다', () => {
    const data = createHandoff('PROJ-4', 'deploy', { deploy_url: 'https://app.example.com' });
    expect(() => advancePhase(data, {})).toThrow("'deploy'은(는) 마지막 단계입니다.");
  });

  it('원본 데이터를 변경하지 않는다', () => {
    const data = createHandoff('PROJ-5', 'planning', { prd_url: 'https://example.com/prd' });
    advancePhase(data, { figma_url: 'https://figma.com/file/abc' });
    expect(data.current_phase).toBe('planning');
    expect(data.history).toHaveLength(1);
  });
});

describe('getNextPhase', () => {
  const cases: [WorkflowPhase, WorkflowPhase | null][] = [
    ['planning', 'design'],
    ['design', 'development'],
    ['development', 'qa'],
    ['qa', 'deploy'],
    ['deploy', null],
  ];

  for (const [current, expected] of cases) {
    it(`${current} → ${expected ?? 'null'}`, () => {
      expect(getNextPhase(current)).toBe(expected);
    });
  }
});

describe('validateArtifacts', () => {
  it('planning: prd_url이 있으면 승인', () => {
    const gate = validateArtifacts('planning', { prd_url: 'https://example.com/prd' });
    expect(gate.status).toBe('approved');
    expect(gate.type).toBe('auto_pass');
  });

  it('planning: jira_key만 있어도 승인', () => {
    const gate = validateArtifacts('planning', { jira_key: 'PROJ-1' });
    expect(gate.status).toBe('approved');
  });

  it('planning: 필수 산출물 없으면 차단', () => {
    const gate = validateArtifacts('planning', {});
    expect(gate.status).toBe('rejected');
    expect(gate.type).toBe('auto_block');
  });

  it('design: figma_url이 있으면 승인', () => {
    const gate = validateArtifacts('design', { figma_url: 'https://figma.com/file/abc' });
    expect(gate.status).toBe('approved');
  });

  it('design: figma_url 없으면 차단', () => {
    const gate = validateArtifacts('design', {});
    expect(gate.status).toBe('rejected');
  });

  it('development: pr_url이 있으면 승인', () => {
    const gate = validateArtifacts('development', { pr_url: 'https://github.com/org/repo/pull/1' });
    expect(gate.status).toBe('approved');
  });

  it('development: branch만 있어도 승인', () => {
    const gate = validateArtifacts('development', { branch: 'feature/my-feature' });
    expect(gate.status).toBe('approved');
  });

  it('development: 필수 산출물 없으면 차단', () => {
    const gate = validateArtifacts('development', {});
    expect(gate.status).toBe('rejected');
  });

  it('qa: test_report_url이 있으면 승인', () => {
    const gate = validateArtifacts('qa', { test_report_url: 'https://ci.example.com/report/1' });
    expect(gate.status).toBe('approved');
  });

  it('qa: 필수 산출물 없으면 차단', () => {
    const gate = validateArtifacts('qa', {});
    expect(gate.status).toBe('rejected');
  });

  it('deploy: deploy_url이 있으면 승인', () => {
    const gate = validateArtifacts('deploy', { deploy_url: 'https://app.example.com' });
    expect(gate.status).toBe('approved');
  });

  it('deploy: 필수 산출물 없으면 차단', () => {
    const gate = validateArtifacts('deploy', {});
    expect(gate.status).toBe('rejected');
  });

  it('빈 문자열 산출물은 없는 것으로 처리', () => {
    const gate = validateArtifacts('planning', { prd_url: '  ' });
    expect(gate.status).toBe('rejected');
  });
});
