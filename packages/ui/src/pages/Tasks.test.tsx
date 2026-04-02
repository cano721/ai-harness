// @vitest-environment jsdom

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter, useLocation } from 'react-router-dom';
import { Tasks } from './Tasks.js';
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

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: false },
      mutations: { retry: false },
    },
  });
}

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location-probe">{`${location.pathname}${location.search}`}</div>;
}

function renderTasks() {
  const queryClient = makeQueryClient();
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={['/tasks']}>
        <LocationProbe />
        <Tasks />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  eventSourceInstances.length = 0;
});

describe('Tasks page workflow task model', () => {
  it('renders workflow phase state and advances the next phase', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-1',
            projectId: 'project-1',
            title: 'Implement feature: setup-aware task creation',
            status: 'in_progress',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
            metadata: {
              workflow: {
                id: 'implement-feature',
                name: 'Implement Feature',
                separationMode: 'enforced',
                phases: [
                  { id: 'context', label: 'Context', status: 'done' },
                  { id: 'implement', label: 'Implement', status: 'in_progress' },
                  { id: 'validate', label: 'Validate', status: 'pending' },
                  { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
                ],
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [];
      }

      if (path === '/activity?limit=100') {
        return [];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ id: 'task-2' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    expect(await screen.findByText('Implement Feature')).toBeTruthy();
    expect(screen.getByText('next: Implement')).toBeTruthy();
    expect(screen.getByText('Context')).toBeTruthy();
    expect(screen.getByText('Validate')).toBeTruthy();
    expect(screen.getByText('separate review required')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Advance task Implement feature: setup-aware task creation' }));

    await waitFor(() => {
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-1', {
        status: 'in_progress',
        metadata: {
          workflow: {
            id: 'implement-feature',
            name: 'Implement Feature',
            separationMode: 'enforced',
            phases: [
              { id: 'context', label: 'Context', status: 'done' },
              { id: 'implement', label: 'Implement', status: 'done' },
              { id: 'validate', label: 'Validate', status: 'in_progress' },
              { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
            ],
          },
        },
      });
    });
  });

  it('sends enforced workflow into review when the review phase is next', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-2',
            projectId: 'project-1',
            title: 'Implement feature: review handoff',
            status: 'in_progress',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
            metadata: {
              workflow: {
                id: 'implement-feature',
                name: 'Implement Feature',
                separationMode: 'enforced',
                phases: [
                  { id: 'context', label: 'Context', status: 'done' },
                  { id: 'implement', label: 'Implement', status: 'done' },
                  { id: 'validate', label: 'Validate', status: 'in_progress' },
                  { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
                ],
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [
          { id: 'agent-dev', projectId: 'project-1', name: 'developer', adapterType: 'codex_local', status: 'idle' },
          { id: 'agent-review', projectId: 'project-1', name: 'reviewer', adapterType: 'claude_local', status: 'idle' },
        ];
      }

      if (path === '/activity?limit=100') {
        return [];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ id: 'task-2' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    expect(await screen.findByRole('button', { name: 'Send task Implement feature: review handoff to review' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Send task Implement feature: review handoff to review' }));

    await waitFor(() => {
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-2', {
        status: 'in_progress',
        agentId: 'agent-review',
        metadata: {
          workflow: {
            id: 'implement-feature',
            name: 'Implement Feature',
            separationMode: 'enforced',
            phases: [
              { id: 'context', label: 'Context', status: 'done' },
              { id: 'implement', label: 'Implement', status: 'done' },
              { id: 'validate', label: 'Validate', status: 'done' },
              { id: 'review', label: 'Review', status: 'in_progress', enforceSeparation: true },
            ],
          },
        },
      });
    });
  });

  it('blocks and resumes the active workflow phase', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-3',
            projectId: 'project-1',
            title: 'Fix bug: blocked verification',
            status: 'in_progress',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
            metadata: {
              workflow: {
                id: 'fix-bug',
                name: 'Fix Bug',
                separationMode: 'advisory',
                phases: [
                  { id: 'reproduce', label: 'Reproduce', status: 'done' },
                  { id: 'fix', label: 'Fix', status: 'in_progress' },
                  { id: 'regression', label: 'Regression', status: 'pending' },
                ],
              },
            },
          },
          {
            id: 'task-4',
            projectId: 'project-1',
            title: 'Refactor: blocked review',
            status: 'blocked',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
            metadata: {
              workflow: {
                id: 'refactor',
                name: 'Refactor',
                separationMode: 'enforced',
                phases: [
                  { id: 'boundary', label: 'Boundary', status: 'done' },
                  { id: 'protect', label: 'Protect', status: 'blocked' },
                  { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
                ],
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [];
      }

      if (path === '/activity?limit=100') {
        return [];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ id: 'task-3' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    fireEvent.click(await screen.findByRole('button', { name: 'Block task Fix bug: blocked verification' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Resume task Refactor: blocked review' }));

    await waitFor(() => {
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-3', {
        status: 'blocked',
        agentId: null,
        metadata: {
          workflow: {
            id: 'fix-bug',
            name: 'Fix Bug',
            separationMode: 'advisory',
            phases: [
              { id: 'reproduce', label: 'Reproduce', status: 'done' },
              { id: 'fix', label: 'Fix', status: 'blocked' },
              { id: 'regression', label: 'Regression', status: 'pending' },
            ],
          },
        },
      });
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-4', {
        status: 'in_progress',
        agentId: null,
        metadata: {
          workflow: {
            id: 'refactor',
            name: 'Refactor',
            separationMode: 'enforced',
            phases: [
              { id: 'boundary', label: 'Boundary', status: 'done' },
              { id: 'protect', label: 'Protect', status: 'in_progress' },
              { id: 'review', label: 'Review', status: 'pending', enforceSeparation: true },
            ],
          },
        },
      });
    });
  });

  it('runs the reviewer runtime when review phase is active', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-5',
            projectId: 'project-1',
            agentId: 'agent-review',
            title: 'Implement feature: active review run',
            status: 'in_progress',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
            metadata: {
              workflow: {
                id: 'implement-feature',
                name: 'Implement Feature',
                separationMode: 'enforced',
                phases: [
                  { id: 'context', label: 'Context', status: 'done' },
                  { id: 'implement', label: 'Implement', status: 'done' },
                  { id: 'validate', label: 'Validate', status: 'done' },
                  { id: 'review', label: 'Review', status: 'in_progress', enforceSeparation: true },
                ],
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [
          { id: 'agent-review', projectId: 'project-1', name: 'reviewer', adapterType: 'claude_local', status: 'idle' },
        ];
      }

      if (path === '/activity?limit=100') {
        return [];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ status: 'started' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    fireEvent.click(await screen.findByRole('button', { name: 'Run review for task Implement feature: active review run' }));

    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/tasks/task-5/run', { agentId: 'agent-review' });
    });
  });

  it('resumes a blocked review with the reviewer runtime when a reviewer is available', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-6',
            projectId: 'project-1',
            agentId: 'agent-dev',
            title: 'Implement feature: blocked review recovery',
            status: 'blocked',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
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
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [
          { id: 'agent-dev', projectId: 'project-1', name: 'developer', adapterType: 'codex_local', status: 'busy' },
          { id: 'agent-review', projectId: 'project-1', name: 'reviewer', adapterType: 'claude_local', status: 'idle' },
        ];
      }

      if (path === '/activity?limit=100') {
        return [];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ status: 'started' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    fireEvent.click(await screen.findByRole('button', { name: 'Resume review for task Implement feature: blocked review recovery' }));

    await waitFor(() => {
      expect(api.patch).toHaveBeenCalledWith('/tasks/task-6', {
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
          },
        },
      });
      expect(api.post).toHaveBeenCalledWith('/tasks/task-6/run', { agentId: 'agent-review' });
    });
  });

  it('shows the reviewer-missing blocked reason on the task card', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-7',
            projectId: 'project-1',
            title: 'Implement feature: missing reviewer',
            status: 'blocked',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
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
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [];
      }

      if (path === '/activity?limit=100') {
        return [];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ status: 'started' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    expect(await screen.findByText('No idle reviewer agent available for the active review phase.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Apply Reviewer Setup' }));
    await waitFor(() => {
      expect(api.post).toHaveBeenCalledWith('/projects/project-1/setup/apply', {
        axes: ['gear'],
        operationIds: ['gear-reviewer-agent'],
      });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Open Reviewer Setup' }));
    expect(screen.getByTestId('location-probe').textContent).toBe('/projects/project-1?setupAxes=gear&setupOps=gear-reviewer-agent&setupExpanded=gear');
  });

  it('shows review completion status after the reviewer phase finishes', async () => {
    vi.mocked(api.get).mockImplementation(async (path: string) => {
      if (path === '/tasks') {
        return [
          {
            id: 'task-8',
            projectId: 'project-1',
            agentId: 'agent-review',
            title: 'Implement feature: review finished',
            status: 'done',
            createdAt: '2026-04-02T00:00:00.000Z',
            updatedAt: '2026-04-02T00:00:00.000Z',
            metadata: {
              workflow: {
                id: 'implement-feature',
                name: 'Implement Feature',
                separationMode: 'enforced',
                lastCompletedPhaseId: 'review',
                lastCompletedAgentId: 'agent-review',
                phases: [
                  { id: 'implement', label: 'Implement', status: 'done' },
                  { id: 'review', label: 'Review', status: 'done', enforceSeparation: true },
                ],
              },
            },
          },
        ];
      }

      if (path === '/projects') {
        return [{ id: 'project-1', name: 'Control Plane Test' }];
      }

      if (path === '/agents') {
        return [
          { id: 'agent-review', projectId: 'project-1', name: 'reviewer', adapterType: 'claude_local', status: 'idle' },
        ];
      }

      if (path === '/activity?limit=100') {
        return [
          {
            id: 'activity-0',
            eventType: 'task.started',
            createdAt: '2026-04-02T00:55:00.000Z',
            detail: {
              taskId: 'task-8',
              runId: 'run-review-1',
              workflowPhase: {
                from: 'Review',
                to: 'Review',
                outcome: 'advanced',
              },
            },
          },
          {
            id: 'activity-1',
            eventType: 'task.completed',
            createdAt: '2026-04-02T01:00:00.000Z',
            detail: {
              taskId: 'task-8',
              runId: 'run-review-1',
              workflowPhase: {
                from: 'Review',
                outcome: 'completed',
              },
            },
          },
        ];
      }

      throw new Error(`Unhandled GET ${path}`);
    });

    vi.mocked(api.post).mockResolvedValue({ status: 'started' });
    vi.mocked(api.patch).mockResolvedValue(undefined);

    renderTasks();

    expect(await screen.findByText('Review completed. Workflow is done.')).toBeTruthy();
    expect(screen.getByText('Review run started.')).toBeTruthy();
    expect(screen.getByText('recent run timeline')).toBeTruthy();
    expect(screen.getByText('started Review')).toBeTruthy();
    expect(screen.getByText('passed Review')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open timeline event passed Review for task Implement feature: review finished' }));
    expect(screen.getByText('Timeline Detail: passed Review')).toBeTruthy();
    expect(screen.getByText('event: task.completed')).toBeTruthy();
    expect(screen.getByText('phase: Review -> Review')).toBeTruthy();
    expect(screen.getByText('outcome: completed')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Load Run Logs' }));
    expect(eventSourceInstances[0]?.url).toBe('/api/tasks/runs/run-review-1/stream');
    eventSourceInstances[0]?.emit('log', { line: '[stdout] review ok' });
    expect(await screen.findByText('[stdout] review ok')).toBeTruthy();
    eventSourceInstances[0]?.emit('done', { runId: 'run-review-1', exitCode: 0, timedOut: false });
    expect(await screen.findByText('run finished: exitCode 0')).toBeTruthy();
  });
});
