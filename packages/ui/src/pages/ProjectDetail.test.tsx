// @vitest-environment jsdom

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom';
import { ProjectDetail } from './ProjectDetail.js';
import { api } from '../api/client.js';

vi.mock('../api/client.js', () => ({
  api: {
    get: vi.fn(),
    post: vi.fn(),
    patch: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}));

const eventSourceInstances: Array<{
  url: string;
  onmessage: ((event: MessageEvent<string>) => void) | null;
  onerror: (() => void) | null;
  addEventListener: (type: string, listener: EventListener) => void;
  emit: (type: string, payload: unknown) => void;
  close: () => void;
}> = [];

class MockEventSource {
  url: string;

  onmessage: ((event: MessageEvent<string>) => void) | null = null;

  onerror: (() => void) | null = null;

  listeners = new Map<string, EventListener[]>();

  constructor(url: string) {
    this.url = url;
    eventSourceInstances.push(this as unknown as (typeof eventSourceInstances)[number]);
  }

  addEventListener(type: string, listener: EventListener) {
    const current = this.listeners.get(type) ?? [];
    this.listeners.set(type, [...current, listener]);
  }

  emit(type: string, payload: unknown) {
    const event = { data: JSON.stringify(payload) } as MessageEvent<string>;
    if (type === 'message') {
      this.onmessage?.(event);
      return;
    }
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event as unknown as Event);
    }
  }

  close() {}
}

vi.stubGlobal('EventSource', MockEventSource);

const project = {
  id: 'project-1',
  name: 'Control Plane Test',
  path: '/tmp/control-plane-test',
  createdAt: '2026-04-02T00:00:00.000Z',
};

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
      },
      mutations: {
        retry: false,
      },
    },
  });
}

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location-probe">{`${location.pathname}${location.search}`}</div>;
}

function renderProjectDetail(initialEntry = '/projects/project-1') {
  const queryClient = makeQueryClient();

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <LocationProbe />
        <Routes>
          <Route path="/projects/:id" element={<ProjectDetail />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

function mockBaseApi({
  analysis,
  setupStatus,
  goals = [],
  automation = null,
  agents = [],
  tasks = [],
  activity = [],
  runLogs = {},
}: {
  analysis: Record<string, unknown>;
  setupStatus: Record<string, unknown>;
  goals?: Array<Record<string, unknown>>;
  automation?: Record<string, unknown> | null;
  agents?: Array<Record<string, unknown>>;
  tasks?: Array<Record<string, unknown>>;
  activity?: Array<Record<string, unknown>>;
  runLogs?: Record<string, string[]>;
}) {
  const getImpl = async (path: string) => {
    if (path === '/projects/project-1') return project;
    if (path === '/projects/project-1/goals') return goals;
    if (path === '/projects/project-1/automation') return automation;
    if (path === '/projects/project-1/setup/status') return setupStatus;
    if (path === '/agents') return agents;
    if (path === '/tasks') return tasks;
    if (path.startsWith('/tasks/runs/') && path.endsWith('/logs')) {
      const runId = path.split('/')[3] ?? '';
      return runLogs[runId] ?? [];
    }
    if (path === '/costs/by-project') return [];
    if (path === '/relations/project-1') return [];
    if (path === '/activity?projectId=project-1&limit=20' || path === '/activity?projectId=project-1&limit=100') return activity;
    throw new Error(`Unhandled GET ${path}`);
  };

  vi.mocked(api.get).mockImplementation(getImpl);

  vi.mocked(api.post).mockImplementation(async (path: string, body: unknown) => {
    if (path === '/projects/analyze') {
      expect(body).toEqual({ path: project.path });
      return analysis;
    }
    if (path === '/tasks') {
      return {
        id: 'task-1',
        projectId: 'project-1',
        title: (body as { title: string }).title,
      };
    }
    if (path.startsWith('/tasks/') && path.endsWith('/run')) {
      const taskId = path.split('/')[2] ?? 'task-1';
      return {
        id: `run-${taskId}`,
        taskId,
        status: 'running',
      };
    }
    if (path === '/projects/project-1/setup/apply') {
      const { axes, operationIds = [], force = false } = body as { axes: string[]; operationIds?: string[]; force?: boolean };

      if (axes.includes('guide') && operationIds.includes('guide-claude')) {
        return {
          projectId: 'project-1',
          appliedAxes: ['guide'],
          results: [
            {
              id: 'guide-claude',
              axis: 'guide',
              title: 'CLAUDE.md',
              outcome: 'created',
              detail: force ? 'CLAUDE.md was reset to the setup baseline.' : 'CLAUDE.md was created.',
            },
          ],
        };
      }

      if (axes.includes('gear') && operationIds.some((id) => id.startsWith('gear-'))) {
        return {
          projectId: 'project-1',
          appliedAxes: ['gear'],
          results: operationIds.map((operationId) => ({
            id: operationId,
            axis: 'gear' as const,
            title:
              operationId === 'gear-developer-agent'
                ? 'Developer agent'
                : operationId === 'gear-reviewer-agent'
                  ? 'Reviewer agent'
                  : operationId === 'gear-workflow-feature'
                    ? 'Feature workflow'
                    : operationId === 'gear-workflow-bug'
                      ? 'Bug workflow'
                      : 'Refactor workflow',
            outcome: force ? 'updated' as const : 'created' as const,
            detail: force ? `${operationId} was reset.` : `${operationId} was created.`,
          })),
        };
      }

      if (axes.includes('guide') && operationIds.some((id) => id !== 'guide-claude')) {
        return {
          projectId: 'project-1',
          appliedAxes: ['guide'],
          results: operationIds.map((operationId) => ({
            id: operationId,
            axis: 'guide' as const,
            title: operationId,
            outcome: force ? 'updated' as const : 'created' as const,
            detail: force ? `${operationId} was reset.` : `${operationId} was created.`,
          })),
        };
      }

      return {
        projectId: 'project-1',
        appliedAxes: axes as Array<'guard' | 'guide' | 'gear'>,
        results: [],
      };
    }
    if (path === '/projects/project-1/goals') {
      return {
        id: 'goal-created',
        projectId: 'project-1',
        title: (body as { title: string }).title,
        description: (body as { description?: string }).description ?? null,
        parentGoalId: (body as { parentGoalId?: string | null }).parentGoalId ?? null,
        status: 'planned',
        createdAt: '2026-04-02T00:00:00.000Z',
        updatedAt: '2026-04-02T00:00:00.000Z',
      };
    }
    if (path === '/projects/project-1/automation/run') {
      return {
        projectId: 'project-1',
        routineId: 'routine-1',
        evaluatedAt: '2026-04-03T00:00:00.000Z',
        createdTasks: [
          {
            taskId: 'task-goal-1',
            goalId: 'goal-1',
            goalTitle: 'UX and product polish',
            stage: 'implement',
            agentId: 'agent-dev',
            title: 'Advance UX and product polish',
          },
        ],
        updatedGoals: [{ goalId: 'goal-1', status: 'active' }],
        skippedGoals: [],
        summary: 'Created 1 automation task(s).',
      };
    }
    if (path === '/projects/project-1/setup/plan') {
      const { axes = [], operationIds = [] } = body as { axes?: string[]; operationIds?: string[] };
      return {
        projectId: 'project-1',
        axes: axes.map((axis) => {
          const axisStatus = ((setupStatus.axes as Array<Record<string, unknown>>) ?? []).find((item) => item.axis === axis);
          const axisOperations = ((axisStatus?.operations as Array<Record<string, unknown>> | undefined) ?? [])
            .filter((operation) => operationIds.includes(String(operation.id)));

          return {
            axis,
            label: axis,
            ready: false,
            readiness: 0,
            summary: `${axis} preview`,
            operations: axisOperations.map((operation) => {
              const operationId = String(operation.id);
              return {
                id: operationId,
                axis,
                title: operationId,
                description: `${operationId} preview`,
                scope: 'project' as const,
                status: 'pending' as const,
                preview: {
                  kind: 'file' as const,
                  summary: `${operationId} preview`,
                  diffSummary: {
                    additions: 1,
                    removals: 0,
                    summary: '1 baseline line(s) will be added.',
                    additionsSample: ['# sample baseline'],
                  },
                  comparePreview: {
                    baseline: ['# sample baseline'],
                    current: [],
                  },
                },
              };
            }),
          };
        }),
        totals: { ready: 0, pending: operationIds.length },
        summary: operationIds.length > 0 ? `${operationIds.length} selected operation(s)` : 'No-op in test',
      };
    }
    throw new Error(`Unhandled POST ${path}`);
  });

  vi.mocked(api.patch).mockResolvedValue(undefined);
  vi.mocked(api.put).mockImplementation(async (path: string, body: unknown) => {
    if (path === '/projects/project-1/automation') {
      return {
        id: 'routine-1',
        projectId: 'project-1',
        name: (body as { name: string }).name,
        description: (body as { description?: string }).description ?? null,
        status: (body as { status: string }).status,
        heartbeatMinutes: (body as { heartbeatMinutes: number }).heartbeatMinutes,
        developerAgentId: (body as { developerAgentId?: string | null }).developerAgentId ?? null,
        reviewerAgentId: (body as { reviewerAgentId?: string | null }).reviewerAgentId ?? null,
        verifierAgentId: (body as { verifierAgentId?: string | null }).verifierAgentId ?? null,
        createdAt: '2026-04-02T00:00:00.000Z',
        updatedAt: '2026-04-02T00:00:00.000Z',
      };
    }
    return undefined;
  });
  vi.mocked(api.delete).mockResolvedValue(undefined);
}

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  eventSourceInstances.length = 0;
});

describe('ProjectDetail setup-first control plane', () => {
  it('shows setup-managed missing states and routes missing asset creation through setup apply', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: false },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: false, codex: false, cursor: false },
        scores: {
          guard: { score: 20, details: [] },
          guide: { score: 30, details: [] },
          gear: { score: 10, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: false,
        mode: 'workspace',
        summary: 'Setup is still required.',
        axes: [
          {
            axis: 'guard',
            label: 'Guard',
            ready: false,
            readiness: 0,
            summary: 'Workspace guard assets are missing.',
            operations: [{ id: 'guard-hooks', axis: 'guard', title: 'Hooks', description: 'Prepare workspace-local hooks.', path: '.claude/settings.json', scope: 'project', status: 'pending', drift: { state: 'missing', summary: '5 required hook(s) are still missing.' }, preview: { kind: 'config', summary: 'Configure workspace hooks.', diffSummary: { additions: 5, removals: 0, summary: '5 baseline line(s) will be added.', additionsSample: ['bash hooks/block-dangerous.sh'] }, comparePreview: { baseline: ['bash hooks/block-dangerous.sh'], current: [] } } }],
          },
          {
            axis: 'guide',
            label: 'Guide',
            ready: false,
            readiness: 25,
            summary: 'Guide assets are partially missing.',
            operations: [
              { id: 'guide-claude', axis: 'guide', title: 'CLAUDE.md', description: 'Create the project summary guide.', path: 'CLAUDE.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' } },
              { id: 'guide-context-map', axis: 'guide', title: 'Context map', description: 'Create the project map.', path: '.ddalkak/context-map.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' }, preview: { kind: 'file', summary: 'Create the project map.', diffSummary: { additions: 12, removals: 0, summary: '12 baseline line(s) will be added.', additionsSample: ['# Context Map'] }, comparePreview: { baseline: ['# Context Map', '## Project'], current: [] } } },
            ],
          },
          {
            axis: 'gear',
            label: 'Gear',
            ready: false,
            readiness: 0,
            summary: 'Execution prep assets are missing.',
            operations: [
              { id: 'gear-developer-agent', axis: 'gear', title: 'Developer agent', description: 'Prepare reusable project-local execution assets.', path: '.claude/agents/developer.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' }, preview: { kind: 'file', summary: 'Create the developer agent baseline.', diffSummary: { additions: 8, removals: 0, summary: '8 baseline line(s) will be added.', additionsSample: ['# Control Plane Test Developer'] }, comparePreview: { baseline: ['# Control Plane Test Developer'], current: [] } } },
              { id: 'gear-reviewer-agent', axis: 'gear', title: 'Reviewer agent', description: 'Prepare review execution assets.', path: '.claude/agents/reviewer.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' } },
              { id: 'gear-workflow-feature', axis: 'gear', title: 'Feature workflow', description: 'Prepare feature workflow.', path: '.ddalkak/workflows/implement-feature.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' } },
              { id: 'gear-workflow-bug', axis: 'gear', title: 'Bug workflow', description: 'Prepare bug workflow.', path: '.ddalkak/workflows/fix-bug.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' } },
              { id: 'gear-workflow-refactor', axis: 'gear', title: 'Refactor workflow', description: 'Prepare refactor workflow.', path: '.ddalkak/workflows/refactor.md', scope: 'project', status: 'pending', drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' } },
            ],
          },
        ],
      },
    });

    renderProjectDetail();

    expect(await screen.findByText('Project Setup Center')).toBeTruthy();
    expect(await screen.findByText('Runtime CLI not detected')).toBeTruthy();
    expect(await screen.findByText('CLAUDE.md Detail Panel')).toBeTruthy();
    expect(await screen.findByText('Hook Detail Panel')).toBeTruthy();
    expect(await screen.findByText('프로젝트 문서 Detail Panel')).toBeTruthy();
    expect(await screen.findByText(/Gear agent assets are missing/)).toBeTruthy();
    expect(await screen.findByText(/Gear workflow assets are missing/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Implement Feature' }));
    const taskInput = screen.getByPlaceholderText('에이전트에게 지시...') as HTMLInputElement;
    expect(taskInput.value).toBe('Implement feature: ');
    expect((screen.getByRole('textbox', { name: 'Task description' }) as HTMLTextAreaElement).value).toContain('Workflow: Implement Feature');
    expect(screen.getByText('Use the standard feature delivery path with context, implementation, validation, and review.')).toBeTruthy();
    expect(screen.getByText('Review in separate agent')).toBeTruthy();
    expect(screen.getAllByText('Context').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Validate').length).toBeGreaterThan(0);
    expect(screen.getByText('Task Checklist')).toBeTruthy();
    expect(screen.getByText('- Read context map and conventions first (required)')).toBeTruthy();
    expect(screen.getByText('- Verify the user-facing path before finishing (evidence)')).toBeTruthy();
    expect(screen.getByText('- Keep review in a separate agent (required)')).toBeTruthy();
    fireEvent.change(taskInput, { target: { value: 'Implement feature: setup-aware task creation' } });
    fireEvent.click(screen.getByRole('button', { name: '실행' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/tasks', expect.objectContaining({
        projectId: 'project-1',
        title: 'Implement feature: setup-aware task creation',
        description: expect.stringContaining('Workflow: Implement Feature'),
        metadata: {
          workflow: expect.objectContaining({
            id: 'implement-feature',
            name: 'Implement Feature',
            summary: 'Use the standard feature delivery path with context, implementation, validation, and review.',
            source: 'gear',
            separationMode: 'enforced',
            phases: expect.arrayContaining([
              expect.objectContaining({ id: 'context', label: 'Context' }),
              expect.objectContaining({ id: 'review', label: 'Review', enforceSeparation: true }),
            ]),
            checklist: expect.arrayContaining(['Keep review in a separate agent']),
            phaseChecklistMap: expect.objectContaining({
              context: expect.arrayContaining([expect.objectContaining({ label: 'Read context map and conventions first', kind: 'required' })]),
              review: expect.arrayContaining([expect.objectContaining({ label: 'Keep review in a separate agent', kind: 'required' })]),
            }),
          }),
        },
      }));
      expect(api.post).toHaveBeenCalledWith('/tasks/task-1/run', {});
    });
    expect(eventSourceInstances[0]?.url).toBe('/api/tasks/runs/run-task-1/stream');
    fireEvent.click(screen.getByRole('button', { name: 'Focus CLAUDE.md in Setup' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
      });
    });
    expect(await screen.findByRole('button', { name: 'Implement Feature' })).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Fix Bug' })).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Refactor' })).toBeTruthy();
    const showOpsButtons = screen.getAllByRole('button', { name: 'Show Ops' });
    fireEvent.click(showOpsButtons[showOpsButtons.length - 1]);
    expect(await screen.findByText('Prepare reusable project-local execution assets.')).toBeTruthy();
    expect(await screen.findByText('.claude/agents/developer.md')).toBeTruthy();
    expect(await screen.findByText('8 baseline line(s) will be added.')).toBeTruthy();
    expect(await screen.findByText('+ # Control Plane Test Developer')).toBeTruthy();
    expect(await screen.findByText('Baseline')).toBeTruthy();
    expect(await screen.findAllByText('(missing)')).not.toHaveLength(0);
    expect((await screen.findAllByText('missing')).length).toBeGreaterThan(0);

    fireEvent.click(screen.getAllByRole('button', { name: 'Create via Setup' })[0]);

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/apply', { axes: ['guide'], operationIds: ['guide-claude'], force: false });
    });
    expect(await screen.findByText('Apply Result')).toBeTruthy();
    expect(await screen.findByText('Apply Impact')).toBeTruthy();
    expect(await screen.findAllByText('1 changed')).not.toHaveLength(0);
    expect(await screen.findAllByText('1 missing')).not.toHaveLength(0);
    expect(await screen.findByText('Changed now: CLAUDE.md')).toBeTruthy();
    expect(await screen.findByText('Still missing: CLAUDE.md')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Focus Missing' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
      });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Focus Changed' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
      });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Focus apply result CLAUDE.md' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
      });
    });
    expect(await screen.findByText(/Last apply: created CLAUDE\.md/)).toBeTruthy();

    const gearAgentsText = screen.getByText(/Gear agent assets are missing/);
    const gearAgentsBanner = gearAgentsText.parentElement?.parentElement?.parentElement;
    if (!gearAgentsBanner) {
      throw new Error('Gear agents setup banner not found');
    }

    fireEvent.click(within(gearAgentsBanner as HTMLElement).getByRole('button', { name: 'Create via Setup' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/apply', {
        axes: ['gear'],
        operationIds: ['gear-developer-agent', 'gear-reviewer-agent'],
        force: false,
      });
    });
    expect(await screen.findByText(/Last apply: created Developer agent/)).toBeTruthy();
  });

  it('uses selected setup operations from the Setup Center for preview plan', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: false },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: false, cursor: false },
        scores: {
          guard: { score: 20, details: [] },
          guide: { score: 30, details: [] },
          gear: { score: 10, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: false,
        mode: 'workspace',
        summary: 'Setup is still required.',
        axes: [
          {
            axis: 'guide',
            label: 'Guide',
            ready: false,
            readiness: 25,
            summary: 'Guide assets are partially missing.',
            operations: [
              { id: 'guide-claude', axis: 'guide', title: 'CLAUDE.md', description: 'Create the project summary guide.', path: 'CLAUDE.md', scope: 'project', status: 'pending' },
              { id: 'guide-context-map', axis: 'guide', title: 'Context map', description: 'Create the project map.', path: '.ddalkak/context-map.md', scope: 'project', status: 'pending' },
            ],
          },
          {
            axis: 'guard',
            label: 'Guard',
            ready: false,
            readiness: 0,
            summary: 'Workspace guard assets are missing.',
            operations: [{ id: 'guard-hooks', axis: 'guard', title: 'Hooks', description: 'Prepare workspace-local hooks.', path: '.claude/settings.json', scope: 'project', status: 'pending' }],
          },
          {
            axis: 'gear',
            label: 'Gear',
            ready: false,
            readiness: 0,
            summary: 'Execution prep assets are missing.',
            operations: [{ id: 'gear-developer-agent', axis: 'gear', title: 'Developer agent', description: 'Prepare reusable project-local execution assets.', path: '.claude/agents/developer.md', scope: 'project', status: 'pending' }],
          },
        ],
      },
    });

    renderProjectDetail();

    expect(await screen.findByText('Project Setup Center')).toBeTruthy();
    expect(await screen.findAllByRole('button', { name: 'Show Ops' })).toHaveLength(3);
    expect(await screen.findByText('Selected Scope')).toBeTruthy();
    expect(await screen.findAllByText('4 operation(s)')).not.toHaveLength(0);
    expect(await screen.findByRole('button', { name: 'Focus selected CLAUDE.md' })).toBeTruthy();

    fireEvent.click(screen.getAllByRole('button', { name: 'Show Ops' })[0]);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Select Context map' }));
    expect(await screen.findAllByText('3 operation(s)')).not.toHaveLength(0);
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide', 'guard', 'gear'],
        operationIds: ['guide-claude', 'guard-hooks', 'gear-developer-agent'],
      });
    });

    expect(await screen.findByText('3 selected operation(s)')).toBeTruthy();
    expect(await screen.findAllByText('1 baseline line(s) will be added.')).not.toHaveLength(0);
    expect(await screen.findByRole('button', { name: 'Focus plan item guard-hooks' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Focus plan item guard-hooks' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guard'],
        operationIds: ['guard-hooks'],
      });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Apply plan item guard-hooks' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/apply', {
        axes: ['guard'],
        operationIds: ['guard-hooks'],
      });
    });
  });

  it('focuses reviewer setup from a blocked review task reason', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: true, content: '# Guide' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 70, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: false,
        mode: 'workspace',
        summary: 'Reviewer setup is still required.',
        axes: [
          {
            axis: 'guard',
            label: 'Guard',
            ready: true,
            readiness: 100,
            summary: 'Guard ready.',
            operations: [],
          },
          {
            axis: 'guide',
            label: 'Guide',
            ready: true,
            readiness: 100,
            summary: 'Guide ready.',
            operations: [],
          },
          {
            axis: 'gear',
            label: 'Gear',
            ready: false,
            readiness: 50,
            summary: 'Reviewer setup missing.',
            operations: [
              { id: 'gear-reviewer-agent', axis: 'gear', title: 'Reviewer agent', description: 'Prepare review execution assets.', path: '.claude/agents/reviewer.md', scope: 'project', status: 'pending' },
            ],
          },
        ],
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'developer', adapterType: 'codex_local', status: 'idle' },
      ],
      tasks: [
        {
          id: 'task-blocked',
          projectId: 'project-1',
          agentId: 'agent-dev',
          title: 'Implement feature: missing reviewer',
          status: 'blocked',
          createdAt: '2026-04-02T00:00:00.000Z',
          metadata: {
            workflow: {
              id: 'implement-feature',
              name: 'Implement Feature',
              separationMode: 'enforced',
              lastBlockedReason: 'No idle reviewer agent available for the active review phase.',
              phases: [
                { id: 'implement', label: 'Implement', status: 'done' },
                { id: 'review', label: 'Review', status: 'blocked', enforceSeparation: true },
              ],
              checklist: [],
            },
          },
        },
      ],
    });

    renderProjectDetail();

    expect(await screen.findByText('No idle reviewer agent available for the active review phase.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Apply Reviewer Setup' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/apply', {
        axes: ['gear'],
        operationIds: ['gear-reviewer-agent'],
        force: false,
      });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Focus Reviewer Setup' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['gear'],
        operationIds: ['gear-reviewer-agent'],
      });
    });
  });

  it('resumes a blocked review task from Project Detail when a reviewer is available', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: true, content: '# Guide' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 80, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Reviewer assets are ready.',
        axes: [
          { axis: 'guard', label: 'Guard', ready: true, readiness: 100, summary: 'Guard ready.', operations: [] },
          { axis: 'guide', label: 'Guide', ready: true, readiness: 100, summary: 'Guide ready.', operations: [] },
          {
            axis: 'gear',
            label: 'Gear',
            ready: true,
            readiness: 100,
            summary: 'Gear ready.',
            operations: [
              { id: 'gear-reviewer-agent', axis: 'gear', title: 'Reviewer agent', description: 'Prepare review execution assets.', path: '.claude/agents/reviewer.md', scope: 'project', status: 'ready' },
            ],
          },
        ],
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'developer', adapterType: 'codex_local', status: 'busy' },
        { id: 'agent-review', projectId: 'project-1', name: 'reviewer', adapterType: 'claude_local', status: 'idle' },
      ],
      tasks: [
        {
          id: 'task-review-recovery',
          projectId: 'project-1',
          agentId: 'agent-dev',
          title: 'Implement feature: blocked review recovery',
          status: 'blocked',
          createdAt: '2026-04-02T00:00:00.000Z',
          metadata: {
            workflow: {
              id: 'implement-feature',
              name: 'Implement Feature',
              separationMode: 'enforced',
              lastBlockedReason: 'No idle reviewer agent available for the active review phase.',
              phases: [
                { id: 'implement', label: 'Implement', status: 'done' },
                { id: 'review', label: 'Review', status: 'blocked', enforceSeparation: true },
              ],
              checklist: [],
            },
          },
        },
      ],
    });

    renderProjectDetail();

    fireEvent.click(await screen.findByRole('button', { name: 'Resume review for task Implement feature: blocked review recovery' }));

    await waitFor(() => {
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-review-recovery', {
        status: 'in_progress',
        agentId: 'agent-review',
        metadata: {
          workflow: {
            id: 'implement-feature',
            name: 'Implement Feature',
            separationMode: 'enforced',
            phases: [
              { id: 'implement', label: 'Implement', status: 'done' },
              { id: 'review', label: 'Review', status: 'in_progress', enforceSeparation: true },
            ],
            checklist: [],
          },
        },
      });
      expect(api.post).toHaveBeenCalledWith('/tasks/task-review-recovery/run', { agentId: 'agent-review' });
    });
  });

  it('shows required handoff blockers from the server in Project Detail', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: true, content: '# CLAUDE' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 80, details: [] },
          guide: { score: 90, details: [] },
          gear: { score: 70, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Setup is ready.',
        axes: [],
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'developer', adapterType: 'codex_local', status: 'idle' },
      ],
      tasks: [
        {
          id: 'task-blocked-handoff',
          projectId: 'project-1',
          agentId: 'agent-dev',
          title: 'Implement feature: blocked by required checklist',
          status: 'in_progress',
          createdAt: '2026-04-02T00:00:00.000Z',
          metadata: {
            workflow: {
              id: 'implement-feature',
              name: 'Implement Feature',
              source: 'gear',
              separationMode: 'enforced',
              phases: [
                { id: 'implement', label: 'Implement', objective: 'Ship the smallest coherent slice.', status: 'in_progress' },
                { id: 'review', label: 'Review', objective: 'Request a separate review pass.', status: 'pending', enforceSeparation: true },
              ],
              checklist: ['Read context map'],
              phaseChecklistMap: {
                implement: [{ id: 'context-required', label: 'Read context map', kind: 'required' }],
              },
              completedChecklist: [],
            },
          },
        },
      ],
      activity: [],
    });

    vi.spyOn(window, 'confirm').mockReturnValue(true);
    vi.mocked(api.patch)
      .mockRejectedValueOnce({
        status: 409,
        body: {
          error: 'Complete required checklist items before leaving Implement: Read context map',
          data: {
            phaseId: 'implement',
            phaseLabel: 'Implement',
            requiredItems: [{ id: 'context-required', label: 'Read context map', kind: 'required' }],
          },
        },
      })
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce({
        status: 409,
        body: {
          error: 'Complete required checklist items before leaving Implement: Read context map',
          data: {
            phaseId: 'implement',
            phaseLabel: 'Implement',
            requiredItems: [{ id: 'context-required', label: 'Read context map', kind: 'required' }],
          },
        },
      });

    renderProjectDetail();

    fireEvent.click(await screen.findByRole('button', { name: 'Advance task Implement feature: blocked by required checklist' }));

    expect(await screen.findByText('Required checklist items are blocking Implement handoff.')).toBeTruthy();
    expect(await screen.findByText('Run Timeline Drawer')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Complete required blocker Read context map for task Implement feature: blocked by required checklist' }));
    expect(await screen.findByText('Required blockers cleared. Retry the handoff when ready.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry handoff to review for task Implement feature: blocked by required checklist' }));
    expect(await screen.findByText('Handoff blocked again. Resolve the remaining required checklist items.')).toBeTruthy();
  });

  it('shows review blocked-again feedback in Project Detail', async () => {
    const activityEntries = [
      {
        id: 'activity-review-started',
        projectId: 'project-1',
        eventType: 'task.started',
        createdAt: '2026-04-02T00:08:00.000Z',
        detail: {
          taskId: 'task-review-blocked',
          runId: 'run-review-blocked',
          workflowPhase: {
            from: 'Review',
            to: 'Review',
            outcome: 'advanced',
          },
        },
      },
      {
        id: 'activity-review-blocked',
        projectId: 'project-1',
        eventType: 'task.failed',
        createdAt: '2026-04-02T00:10:00.000Z',
        detail: {
          taskId: 'task-review-blocked',
          runId: 'run-review-blocked',
          workflowPhase: {
            from: 'Review',
            to: 'Review',
            outcome: 'blocked',
          },
        },
      },
    ];

    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: true, content: '# Guide' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 100, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Setup ready.',
        axes: [
          { axis: 'guard', label: 'Guard', ready: true, readiness: 100, summary: 'Guard ready.', operations: [] },
          { axis: 'guide', label: 'Guide', ready: true, readiness: 100, summary: 'Guide ready.', operations: [] },
          { axis: 'gear', label: 'Gear', ready: true, readiness: 100, summary: 'Gear ready.', operations: [] },
        ],
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'developer', adapterType: 'codex_local', status: 'busy' },
        { id: 'agent-review', projectId: 'project-1', name: 'reviewer', adapterType: 'claude_local', status: 'idle' },
      ],
      tasks: [
        {
          id: 'task-review-blocked',
          projectId: 'project-1',
          agentId: 'agent-dev',
          title: 'Implement feature: review blocked again',
          status: 'blocked',
          createdAt: '2026-04-02T00:00:00.000Z',
          metadata: {
            workflow: {
              id: 'implement-feature',
              name: 'Implement Feature',
              source: 'gear',
              separationMode: 'enforced',
              lastCompletedPhaseId: 'implement',
              lastCompletedAgentId: 'agent-dev',
              phases: [
                { id: 'implement', label: 'Implement', objective: 'Ship the smallest coherent slice.', status: 'done' },
                { id: 'review', label: 'Review', objective: 'Request a separate review pass.', status: 'blocked', enforceSeparation: true },
              ],
              checklist: [],
            },
          },
        },
      ],
      activity: activityEntries,
    });

    const originalPost = vi.mocked(api.post).getMockImplementation();
    vi.mocked(api.post).mockImplementation(async (path: string, body: unknown) => {
      if (path === '/tasks/task-review-blocked/run') {
        activityEntries.unshift({
          id: 'activity-review-retry',
          projectId: 'project-1',
          eventType: 'task.started',
          createdAt: '2026-04-02T00:12:00.000Z',
          detail: {
            taskId: 'task-review-blocked',
            runId: 'run-review-retry',
            workflowPhase: {
              from: 'Review',
              to: 'Review',
              outcome: 'advanced',
            },
          },
        });
      }
      return originalPost ? await originalPost(path, body) : undefined;
    });

    renderProjectDetail();

    expect(await screen.findByText('Review blocked again. Inspect the reviewer run or retry with another reviewer.')).toBeTruthy();
    expect(screen.getByText('Review run started.')).toBeTruthy();
    expect(screen.getByText('recent run timeline')).toBeTruthy();
    expect(screen.getByText('started Review')).toBeTruthy();
    expect(screen.getByText('failed Review')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open timeline event failed Review for task Implement feature: review blocked again' }));
    expect(screen.getByText('Timeline Detail: failed Review')).toBeTruthy();
    expect(screen.getByText('event: task.failed')).toBeTruthy();
    expect(screen.getByText('phase: Review -> Review')).toBeTruthy();
    expect(screen.getByText('outcome: blocked')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Load Run Logs' }));
    expect(eventSourceInstances[eventSourceInstances.length - 1]?.url).toBe('/api/tasks/runs/run-review-blocked/stream');
    eventSourceInstances[eventSourceInstances.length - 1]?.emit('log', { line: '[stderr] review failed' });
    expect(await screen.findByText('[stderr] review failed')).toBeTruthy();
    eventSourceInstances[eventSourceInstances.length - 1]?.emit('done', { runId: 'run-review-blocked', exitCode: 1, timedOut: false });
    expect(await screen.findByText('run finished: exitCode 1')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry Review' }));
    expect(screen.getByText('retrying review...')).toBeTruthy();

    await waitFor(() => {
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-review-blocked', {
        status: 'in_progress',
        agentId: 'agent-review',
        metadata: {
          workflow: {
            id: 'implement-feature',
            name: 'Implement Feature',
            source: 'gear',
            separationMode: 'enforced',
            lastCompletedPhaseId: 'implement',
            lastCompletedAgentId: 'agent-dev',
            phases: [
              { id: 'implement', label: 'Implement', objective: 'Ship the smallest coherent slice.', status: 'done' },
              { id: 'review', label: 'Review', objective: 'Request a separate review pass.', status: 'in_progress', enforceSeparation: true },
            ],
            checklist: [],
          },
        },
      });
      expect(api.post).toHaveBeenCalledWith('/tasks/task-review-blocked/run', { agentId: 'agent-review' });
    });
    await waitFor(() => {
      expect(eventSourceInstances[eventSourceInstances.length - 1]?.url).toBe('/api/tasks/runs/run-review-retry/stream');
    });
    expect(await screen.findByText('Timeline Detail: started Review')).toBeTruthy();
    expect(screen.getByText('previous runs')).toBeTruthy();
    const previousRunButton = screen.getByRole('button', { name: 'Open previous timeline event failed Review for task Implement feature: review blocked again' });
    expect(previousRunButton.textContent).toContain('blocked');
    expect(previousRunButton.textContent).toContain('exitCode 1');
    expect(previousRunButton.textContent).toContain('replaced by started Review');
    fireEvent.click(screen.getByRole('button', { name: 'Load logs for previous timeline event failed Review for task Implement feature: review blocked again' }));
    expect(eventSourceInstances[eventSourceInstances.length - 1]?.url).toBe('/api/tasks/runs/run-review-blocked/stream');
    fireEvent.click(screen.getByRole('button', { name: 'Jump to replacement timeline event started Review for task Implement feature: review blocked again' }));
    expect(await screen.findByText('Timeline Detail: started Review')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open full timeline for task Implement feature: review blocked again' }));
    expect(await screen.findByText('Full Timeline')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Jump to replacement full timeline event started Review for task Implement feature: review blocked again' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open run drawer for task Implement feature: review blocked again' }));
    await screen.findByText('Run Timeline Drawer');
    const closeDrawerButton = screen.getAllByRole('button', { name: 'Close run drawer for task Implement feature: review blocked again' }).at(-1);
    expect(closeDrawerButton).toBeTruthy();
    const drawer = closeDrawerButton!.parentElement?.parentElement;
    expect(drawer).toBeTruthy();
    const drawerScope = within(drawer!);
    expect(drawerScope.getByText('description')).toBeTruthy();
    expect(drawerScope.getByText('No description')).toBeTruthy();
    expect(drawerScope.getByText('workflow')).toBeTruthy();
    expect(drawerScope.getAllByText('Implement Feature').length).toBeGreaterThan(0);
    expect(drawerScope.getByText('current phase')).toBeTruthy();
    expect(drawerScope.getAllByText('Review').length).toBeGreaterThan(0);
    expect(drawerScope.getByText('phase objective')).toBeTruthy();
    expect(drawerScope.getByText('Request a separate review pass.')).toBeTruthy();
    expect(drawerScope.getByText('agent')).toBeTruthy();
    expect(drawerScope.getByText('developer')).toBeTruthy();
    expect(drawerScope.getAllByText('reviewer').length).toBeGreaterThan(0);
    expect(drawerScope.getByText('source')).toBeTruthy();
    expect(drawerScope.getByText('gear')).toBeTruthy();
    expect(drawerScope.getByText('separation mode')).toBeTruthy();
    expect(drawerScope.getByText('enforced')).toBeTruthy();
    expect(drawerScope.getByText('phase owner')).toBeTruthy();
    expect(drawerScope.getAllByText('reviewer').length).toBeGreaterThan(0);
    expect(drawerScope.getByText('setup origin')).toBeTruthy();
    expect(drawerScope.getByText('gear workflow')).toBeTruthy();
    expect(drawerScope.getByText('CLAUDE.md')).toBeTruthy();
    expect(drawerScope.getByText('reviewer agent asset')).toBeTruthy();
    expect(drawerScope.getByText('phase policy')).toBeTruthy();
    expect(drawerScope.getByText(/Use a different agent than the previous completed phase\./)).toBeTruthy();
    expect(drawerScope.getByText(/Reviewer handoff is ready for reviewer\./)).toBeTruthy();
    expect(drawerScope.getByText(/Resolve the blocking condition before resuming this phase\./)).toBeTruthy();
    expect(drawerScope.getByText('orchestration alerts')).toBeTruthy();
    expect(drawerScope.getByText('Agent assigned: developer')).toBeTruthy();
    expect(drawerScope.getByText('Phase blocked')).toBeTruthy();
    expect(drawerScope.getByText('Separation enforced')).toBeTruthy();
    expect(drawerScope.getByText('Reviewer ready: reviewer')).toBeTruthy();
    expect(drawerScope.getByText('agent capabilities')).toBeTruthy();
    expect(drawerScope.getByText('code changes')).toBeTruthy();
    expect(drawerScope.getAllByText('review pass').length).toBeGreaterThan(0);
    expect(drawerScope.getByText('reviewer capabilities')).toBeTruthy();
    expect(drawerScope.getByText('analysis')).toBeTruthy();
    expect(drawerScope.getAllByText('separate context').length).toBeGreaterThan(0);
    expect(drawerScope.getByText('phase track')).toBeTruthy();
    expect(drawerScope.getByText('workflow checklist')).toBeTruthy();
    expect(drawerScope.getByText('No checklist items')).toBeTruthy();
    expect(drawerScope.getByText('phase actions')).toBeTruthy();
    expect(drawerScope.getByRole('button', { name: 'Resume task Implement feature: review blocked again from drawer' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Jump to replacement drawer timeline event started Review for task Implement feature: review blocked again' })).toBeTruthy();
    fireEvent.click(previousRunButton);
    expect(await screen.findByText('Timeline Detail: failed Review')).toBeTruthy();
  });

  it('hydrates Setup Center selection state from the URL', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: false },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: false, cursor: false },
        scores: {
          guard: { score: 20, details: [] },
          guide: { score: 30, details: [] },
          gear: { score: 10, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: false,
        mode: 'workspace',
        summary: 'Setup is still required.',
        axes: [
          {
            axis: 'guide',
            label: 'Guide',
            ready: false,
            readiness: 25,
            summary: 'Guide assets are partially missing.',
            operations: [
              {
                id: 'guide-claude',
                axis: 'guide',
                title: 'CLAUDE.md',
                description: 'Create the project summary guide.',
                path: 'CLAUDE.md',
                scope: 'project',
                status: 'pending',
              },
              {
                id: 'guide-context-map',
                axis: 'guide',
                title: 'Context map',
                description: 'Create the project map.',
                path: '.ddalkak/context-map.md',
                scope: 'project',
                status: 'pending',
                preview: {
                  kind: 'file',
                  summary: 'Create the project map.',
                  comparePreview: {
                    baseline: ['# Context Map'],
                    current: [],
                  },
                },
              },
            ],
          },
          {
            axis: 'guard',
            label: 'Guard',
            ready: false,
            readiness: 0,
            summary: 'Workspace guard assets are missing.',
            operations: [
              { id: 'guard-hooks', axis: 'guard', title: 'Hooks', description: 'Prepare workspace-local hooks.', path: '.claude/settings.json', scope: 'project', status: 'pending' },
            ],
          },
        ],
      },
    });

    renderProjectDetail('/projects/project-1?setupAxes=guide&setupOps=guide-claude,guide-context-map&setupExpanded=guide&setupQuery=context');

    expect(await screen.findByText('Project Setup Center')).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Hide Ops' })).toBeTruthy();
    expect((await screen.findByRole('checkbox', { name: 'Select Context map' }) as HTMLInputElement).checked).toBe(true);
    expect((await screen.findByRole('textbox', { name: 'Filter setup operations' }) as HTMLInputElement).value).toBe('context');
    expect(screen.getByText('1 visible op(s)')).toBeTruthy();
    expect(screen.queryByRole('checkbox', { name: 'Select CLAUDE.md' })).toBeNull();
    expect(screen.getByText('1 hidden selected')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Scope to Visible' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Scope to Visible' }));

    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-context-map'],
      });
    });

    expect(screen.queryByText('1 hidden selected')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Clear Filter' }));
    expect(await screen.findByRole('checkbox', { name: 'Select CLAUDE.md' })).toBeTruthy();
    expect((await screen.findByTestId('location-probe')).textContent).toBe('/projects/project-1?setupAxes=guide&setupOps=guide-context-map&setupExpanded=guide');
  });

  it('keeps existing setup-managed assets editable without showing missing-state CTAs', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: true, content: '# Existing CLAUDE.md' },
        agents: [
          { name: 'developer', path: '.claude/agents/developer.md' },
          { name: 'domain-expert', path: '.claude/agents/domain-expert.md' },
        ],
        hooks: [{ event: 'PreToolUse', commands: ['bash hooks/block-dangerous.sh'] }],
        mcpServers: [],
        docs: [
          { name: 'convention', path: '.ddalkak/docs/convention.md' },
          { name: 'architecture', path: '.ddalkak/docs/architecture.md' },
          { name: 'review', path: '.ddalkak/docs/review.md' },
          { name: 'testing', path: '.ddalkak/docs/testing.md' },
        ],
        skills: [],
        workflows: [
          { name: 'implement-feature', path: '.ddalkak/workflows/implement-feature.md' },
          { name: 'ship-release', path: '.ddalkak/workflows/ship-release.md' },
        ],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: false, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 100, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Workspace is ready.',
        axes: [
          {
            axis: 'guard',
            label: 'Guard',
            ready: true,
            readiness: 100,
            summary: 'Guard is ready.',
            operations: [{ id: 'guard-hooks', axis: 'guard', title: 'Hooks', description: 'Prepare workspace-local hooks.', path: '.claude/settings.json', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Required local security hooks are connected.' } }],
          },
          {
            axis: 'guide',
            label: 'Guide',
            ready: true,
            readiness: 100,
            summary: 'Guide is ready.',
          operations: [
              { id: 'guide-claude', axis: 'guide', title: 'CLAUDE.md', description: 'Create the project summary guide.', path: 'CLAUDE.md', scope: 'project', status: 'ready', drift: { state: 'drifted', summary: 'Differs from the current setup baseline.' }, preview: { kind: 'file', summary: 'Create the project summary guide.', diffSummary: { additions: 2, removals: 1, summary: '2 baseline line(s) to add, 1 custom line(s) to remove.', additionsSample: ['## Guide'], removalsSample: ['# Existing CLAUDE.md'] }, comparePreview: { baseline: ['# Control Plane Test', '## Guide'], current: ['# Existing CLAUDE.md'] } } },
              { id: 'guide-context-map', axis: 'guide', title: 'Context map', description: 'Create the project map.', path: '.ddalkak/context-map.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' }, preview: { kind: 'file', summary: 'Create the project map.', diffSummary: { additions: 0, removals: 0, summary: 'No baseline drift detected.' } } },
              { id: 'guide-convention-doc', axis: 'guide', title: 'Convention doc', description: 'Create the convention doc.', path: '.ddalkak/docs/convention.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
              { id: 'guide-architecture-doc', axis: 'guide', title: 'Architecture doc', description: 'Create the architecture doc.', path: '.ddalkak/docs/architecture.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
              { id: 'guide-review-doc', axis: 'guide', title: 'Review doc', description: 'Create the review doc.', path: '.ddalkak/docs/review.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
            ],
          },
          {
            axis: 'gear',
            label: 'Gear',
            ready: true,
            readiness: 100,
            summary: 'Gear is ready.',
            operations: [
              { id: 'gear-developer-agent', axis: 'gear', title: 'Developer agent', description: 'Prepare reusable project-local execution assets.', path: '.claude/agents/developer.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
              { id: 'gear-reviewer-agent', axis: 'gear', title: 'Reviewer agent', description: 'Prepare review execution assets.', path: '.claude/agents/reviewer.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
              { id: 'gear-workflow-feature', axis: 'gear', title: 'Feature workflow', description: 'Prepare feature workflow.', path: '.ddalkak/workflows/implement-feature.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
              { id: 'gear-workflow-bug', axis: 'gear', title: 'Bug workflow', description: 'Prepare bug workflow.', path: '.ddalkak/workflows/fix-bug.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
              { id: 'gear-workflow-refactor', axis: 'gear', title: 'Refactor workflow', description: 'Prepare refactor workflow.', path: '.ddalkak/workflows/refactor.md', scope: 'project', status: 'ready', drift: { state: 'aligned', summary: 'Matches the current setup baseline.' } },
            ],
          },
        ],
      },
    });

    renderProjectDetail();

    expect(await screen.findByText('Workspace ready')).toBeTruthy();
    expect(screen.queryByText('Runtime CLI not detected')).toBeNull();
    expect(screen.getAllByText('Managed by Setup').length).toBeGreaterThan(0);
    expect(screen.getByText(/에이전트 Detail Panel/)).toBeTruthy();
    expect(screen.getByText('워크플로우 Detail Panel')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Implement Feature' })).toBeTruthy();
    expect(screen.getAllByText('Drifted').length).toBeGreaterThan(0);
    expect(screen.getByText('Differs from the current setup baseline.')).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: 'Show Ops' })[1]);
    expect(await screen.findByText('2 baseline line(s) to add, 1 custom line(s) to remove.')).toBeTruthy();
    expect(await screen.findByText('+ ## Guide')).toBeTruthy();
    expect(await screen.findByText('- # Existing CLAUDE.md')).toBeTruthy();
    expect((await screen.findAllByText('Baseline')).length).toBeGreaterThan(0);
    expect((await screen.findAllByText('Current')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('managed').length).toBeGreaterThan(0);
    expect(screen.getAllByText('custom').length).toBeGreaterThan(0);
    expect(screen.getAllByRole('button', { name: 'Reset via Setup' }).length).toBeGreaterThan(0);

    fireEvent.click(screen.getAllByRole('button', { name: 'Reset via Setup' })[0]);

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/apply', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
        force: true,
      });
    });
    expect(await screen.findByText('Apply Impact')).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Focus Drifted' })).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Keep Aligned' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Keep Aligned' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guard', 'guide', 'gear'],
        operationIds: [
          'guard-hooks',
          'guide-context-map',
          'guide-convention-doc',
          'guide-architecture-doc',
          'guide-review-doc',
          'gear-developer-agent',
          'gear-reviewer-agent',
          'gear-workflow-feature',
          'gear-workflow-bug',
          'gear-workflow-refactor',
        ],
      });
    });

    fireEvent.click(screen.getByRole('button', { name: 'Focus Drifted' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
      });
    });

    fireEvent.click(screen.getByRole('button', { name: 'Focus convention in Setup' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-convention-doc'],
      });
    });

    expect(screen.getByRole('button', { name: '수정' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Hook 초기화' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Create via Setup' })).toBeNull();
  });

  it('can narrow selection to drifted operations only', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['React'],
        git: { isRepo: true, branch: 'main' },
        claudeMd: { exists: true, content: '# Existing CLAUDE.md' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: false, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 100, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Workspace is ready.',
        axes: [
          {
            axis: 'guide',
            label: 'Guide',
            ready: true,
            readiness: 100,
            summary: 'Guide is ready.',
            operations: [
              {
                id: 'guide-claude',
                axis: 'guide',
                title: 'CLAUDE.md',
                description: 'Create the project summary guide.',
                path: 'CLAUDE.md',
                scope: 'project',
                status: 'ready',
                drift: { state: 'drifted', summary: 'Differs from the current setup baseline.' },
              },
              {
                id: 'guide-context-map',
                axis: 'guide',
                title: 'Context map',
                description: 'Create the project map.',
                path: '.ddalkak/context-map.md',
                scope: 'project',
                status: 'ready',
                drift: { state: 'aligned', summary: 'Matches the current setup baseline.' },
              },
            ],
          },
          {
            axis: 'guard',
            label: 'Guard',
            ready: true,
            readiness: 100,
            summary: 'Guard is ready.',
            operations: [
              {
                id: 'guard-hooks',
                axis: 'guard',
                title: 'Hooks',
                description: 'Prepare workspace-local hooks.',
                path: '.claude/settings.json',
                scope: 'project',
                status: 'ready',
                drift: { state: 'aligned', summary: 'Required local security hooks are connected.' },
              },
            ],
          },
        ],
      },
    });

    renderProjectDetail();

    expect(await screen.findByText('Project Setup Center')).toBeTruthy();
    expect(await screen.findAllByRole('button', { name: 'Show Ops' })).toHaveLength(2);
    fireEvent.click(await screen.findByRole('button', { name: 'Drifted Only' }));
    fireEvent.click(screen.getByRole('button', { name: 'Preview Plan' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/plan', {
        axes: ['guide'],
        operationIds: ['guide-claude'],
      });
    });
  });

  it('surfaces goal automation controls and can run the goal check loop', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['TypeScript'],
        git: { isRepo: true, branch: 'feature/ddalkak-platform' },
        claudeMd: { exists: true, content: '# Guide' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 100, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Workspace is ready.',
        axes: [],
      },
      goals: [
        {
          id: 'goal-root',
          projectId: 'project-1',
          title: 'AI Harness ddalkak-platform branch goal',
          description: 'Top-level branch goal',
          status: 'active',
          createdAt: '2026-04-02T00:00:00.000Z',
          updatedAt: '2026-04-02T00:00:00.000Z',
        },
        {
          id: 'goal-1',
          projectId: 'project-1',
          parentGoalId: 'goal-root',
          title: 'UX and product polish',
          description: 'Finish polish items',
          status: 'planned',
          createdAt: '2026-04-02T00:00:00.000Z',
          updatedAt: '2026-04-02T00:00:00.000Z',
        },
      ],
      automation: {
        id: 'routine-1',
        projectId: 'project-1',
        name: 'AI Harness Goal Automation',
        description: 'Keep the branch goal moving.',
        status: 'active',
        heartbeatMinutes: 2,
        developerAgentId: 'agent-dev',
        reviewerAgentId: 'agent-review',
        verifierAgentId: 'agent-verify',
        lastEvaluatedAt: '2026-04-03T00:00:00.000Z',
        createdAt: '2026-04-02T00:00:00.000Z',
        updatedAt: '2026-04-02T00:00:00.000Z',
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'AI Harness Developer', adapterType: 'codex_local', status: 'idle' },
        { id: 'agent-review', projectId: 'project-1', name: 'AI Harness Reviewer', adapterType: 'claude_local', status: 'idle' },
        { id: 'agent-verify', projectId: 'project-1', name: 'AI Harness Verifier', adapterType: 'claude_local', status: 'idle' },
      ],
      tasks: [],
    });

    renderProjectDetail();

    expect(await screen.findByText('Goal Automation Center')).toBeTruthy();
    expect((await screen.findAllByText('AI Harness ddalkak-platform branch goal')).length).toBeGreaterThan(0);
    expect((await screen.findAllByText('UX and product polish')).length).toBeGreaterThan(0);
    expect(await screen.findByDisplayValue('AI Harness Goal Automation')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Run Goal Check Now' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/automation/run', {});
    });

    expect(await screen.findByText('Last automation run')).toBeTruthy();
    expect(await screen.findByText('Created 1 automation task(s).')).toBeTruthy();
    expect(await screen.findByText(/UX and product polish \(implement\)/)).toBeTruthy();
  });

  it('keeps saved unassigned automation agents distinct from recommended defaults', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['TypeScript'],
        git: { isRepo: true, branch: 'feature/ddalkak-platform' },
        claudeMd: { exists: true, content: '# Guide' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 100, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Workspace is ready.',
        axes: [],
      },
      goals: [],
      automation: {
        id: 'routine-1',
        projectId: 'project-1',
        name: 'AI Harness Goal Automation',
        description: 'Keep the branch goal moving.',
        status: 'paused',
        heartbeatMinutes: 2,
        developerAgentId: null,
        reviewerAgentId: null,
        verifierAgentId: null,
        lastEvaluatedAt: null,
        createdAt: '2026-04-02T00:00:00.000Z',
        updatedAt: '2026-04-02T00:00:00.000Z',
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'AI Harness Developer', adapterType: 'codex_local', status: 'idle' },
        { id: 'agent-review', projectId: 'project-1', name: 'AI Harness Reviewer', adapterType: 'claude_local', status: 'idle' },
        { id: 'agent-verify', projectId: 'project-1', name: 'AI Harness Verifier', adapterType: 'claude_local', status: 'idle' },
      ],
      tasks: [],
    });

    renderProjectDetail();

    const developerSelect = await screen.findByRole('combobox', { name: /Developer Agent/i }) as HTMLSelectElement;
    const reviewerSelect = await screen.findByRole('combobox', { name: /Reviewer Agent/i }) as HTMLSelectElement;
    const verifierSelect = await screen.findByRole('combobox', { name: /Verifier Agent/i }) as HTMLSelectElement;

    expect(developerSelect.value).toBe('');
    expect(reviewerSelect.value).toBe('');
    expect(verifierSelect.value).toBe('');
    expect(await screen.findByText('Recommended: AI Harness Developer')).toBeTruthy();
    expect(await screen.findByText('Recommended: AI Harness Reviewer')).toBeTruthy();
    expect(await screen.findByText('Recommended: AI Harness Verifier')).toBeTruthy();
  });

  it('shows blocked feedback when goal check run returns paused 409', async () => {
    mockBaseApi({
      analysis: {
        techStack: ['TypeScript'],
        git: { isRepo: true, branch: 'feature/ddalkak-platform' },
        claudeMd: { exists: true, content: '# Guide' },
        agents: [],
        hooks: [],
        mcpServers: [],
        docs: [],
        skills: [],
        workflows: [],
        conventions: [],
        guardrails: {},
        installedCLIs: { claude: true, codex: true, cursor: false },
        scores: {
          guard: { score: 100, details: [] },
          guide: { score: 100, details: [] },
          gear: { score: 100, details: [] },
        },
      },
      setupStatus: {
        projectId: 'project-1',
        ready: true,
        mode: 'workspace',
        summary: 'Workspace is ready.',
        axes: [],
      },
      goals: [],
      automation: {
        id: 'routine-1',
        projectId: 'project-1',
        name: 'AI Harness Goal Automation',
        description: 'Keep the branch goal moving.',
        status: 'paused',
        heartbeatMinutes: 2,
        developerAgentId: 'agent-dev',
        reviewerAgentId: null,
        verifierAgentId: null,
        lastEvaluatedAt: '2026-04-03T00:00:00.000Z',
        createdAt: '2026-04-02T00:00:00.000Z',
        updatedAt: '2026-04-02T00:00:00.000Z',
      },
      agents: [
        { id: 'agent-dev', projectId: 'project-1', name: 'AI Harness Developer', adapterType: 'codex_local', status: 'idle' },
      ],
      tasks: [],
    });

    const basePost = vi.mocked(api.post).getMockImplementation();
    vi.mocked(api.post).mockImplementation(async (path: string, body: unknown) => {
      if (path === '/projects/project-1/automation/run') {
        const error = new Error('Automation routine is paused') as Error & { status?: number; body?: unknown };
        error.status = 409;
        error.body = { error: 'Automation routine is paused' };
        throw error;
      }
      if (!basePost) throw new Error('Base POST handler missing');
      return basePost(path, body);
    });

    renderProjectDetail();

    fireEvent.click(await screen.findByRole('button', { name: 'Run Goal Check Now' }));

    expect(await screen.findByText('Blocked: Automation routine is paused')).toBeTruthy();
  });
});
