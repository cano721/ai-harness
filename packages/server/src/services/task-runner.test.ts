import { describe, expect, it } from 'vitest';
import { applyWorkflowRunResult } from './task-runner.service.js';

describe('applyWorkflowRunResult', () => {
  it('advances to the next pending phase on success', () => {
    const result = applyWorkflowRunResult(
      {
        id: 'implement-feature',
        name: 'Implement Feature',
        source: 'gear',
        separationMode: 'enforced',
        checklist: [],
        phases: [
          { id: 'context', label: 'Context', status: 'done' },
          { id: 'implement', label: 'Implement', status: 'in_progress' },
          { id: 'validate', label: 'Validate', status: 'pending' },
          { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
        ],
      },
      0,
      'agent-implementer',
    );

    expect(result.taskStatus).toBe('in_progress');
    expect(result.workflow?.phases).toEqual([
      { id: 'context', label: 'Context', status: 'done' },
      { id: 'implement', label: 'Implement', status: 'done' },
      { id: 'validate', label: 'Validate', status: 'in_progress' },
      { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
    ]);
    expect(result.workflow?.lastCompletedPhaseId).toBe('implement');
    expect(result.workflow?.lastCompletedAgentId).toBe('agent-implementer');
    expect(result.phaseTransition).toEqual({
      from: 'Implement',
      to: 'Validate',
      outcome: 'advanced',
    });
  });

  it('completes the workflow when the last active phase succeeds', () => {
    const result = applyWorkflowRunResult(
      {
        id: 'implement-feature',
        name: 'Implement Feature',
        source: 'gear',
        separationMode: 'enforced',
        checklist: [],
        phases: [
          { id: 'context', label: 'Context', status: 'done' },
          { id: 'review', label: 'Review', status: 'in_progress', enforceSeparation: true },
        ],
      },
      0,
      'agent-reviewer',
    );

    expect(result.taskStatus).toBe('done');
    expect(result.workflow?.phases).toEqual([
      { id: 'context', label: 'Context', status: 'done' },
      { id: 'review', label: 'Review', status: 'done', enforceSeparation: true },
    ]);
    expect(result.workflow?.lastCompletedPhaseId).toBe('review');
    expect(result.workflow?.lastCompletedAgentId).toBe('agent-reviewer');
    expect(result.phaseTransition).toEqual({
      from: 'Review',
      outcome: 'completed',
    });
  });

  it('blocks the active phase on failure', () => {
    const result = applyWorkflowRunResult(
      {
        id: 'fix-bug',
        name: 'Fix Bug',
        source: 'gear',
        separationMode: 'advisory',
        checklist: [],
        phases: [
          { id: 'reproduce', label: 'Reproduce', status: 'done' },
          { id: 'fix', label: 'Fix', status: 'in_progress' },
          { id: 'regression', label: 'Regression', status: 'pending' },
        ],
      },
      1,
      'agent-fixer',
    );

    expect(result.taskStatus).toBe('blocked');
    expect(result.workflow?.phases).toEqual([
      { id: 'reproduce', label: 'Reproduce', status: 'done' },
      { id: 'fix', label: 'Fix', status: 'blocked' },
      { id: 'regression', label: 'Regression', status: 'pending' },
    ]);
    expect(result.phaseTransition).toEqual({
      from: 'Fix',
      to: 'Fix',
      outcome: 'blocked',
    });
  });
});
