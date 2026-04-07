import { randomUUID } from 'crypto';
import { EventEmitter } from 'events';
import { createDb, tasks, agents, taskRuns, activityLog, projects, costDaily } from '@ddalkak/db';
import { eq, sql } from 'drizzle-orm';
import { getAdapter } from '../adapters/index.js';
import { DEFAULT_PORT, DEFAULT_HOST } from '@ddalkak/shared';
import { loadSkills } from './skill-loader.service.js';
import type { ExecutionEvidence } from './execution-evidence.service.js';

interface RunTaskOptions {
  taskId: string;
  agentId: string;
  timeoutSec?: number;
  maxTurns?: number;
  executionEvidence?: ExecutionEvidence;
}

export interface TaskLogEvent {
  runId: string;
  stream: 'stdout' | 'stderr';
  chunk: string;
}

export interface TaskDoneEvent {
  runId: string;
  exitCode: number | null;
  timedOut: boolean;
}

interface TaskWorkflowMetadata {
  id: string;
  name: string;
  summary?: string;
  source: 'gear';
  separationMode: 'advisory' | 'enforced';
  lastCompletedPhaseId?: string;
  lastCompletedAgentId?: string;
  phases: Array<{
    id: string;
    label: string;
    objective?: string;
    enforceSeparation?: boolean;
    status?: 'pending' | 'in_progress' | 'done' | 'blocked';
  }>;
  checklist: string[];
}

interface WorkflowRunTransition {
  workflow?: TaskWorkflowMetadata;
  taskStatus: 'in_progress' | 'done' | 'blocked';
  phaseTransition?: {
    from?: string;
    to?: string;
    outcome: 'advanced' | 'completed' | 'blocked' | 'unchanged';
  };
}

export const taskEvents = new EventEmitter();
taskEvents.setMaxListeners(100);

const activeLogs = new Map<string, string[]>();

export function getRunLogs(runId: string): string[] {
  return activeLogs.get(runId) ?? [];
}

export function isRunActive(runId: string): boolean {
  return activeLogs.has(runId);
}

export function applyWorkflowRunResult(
  workflow: TaskWorkflowMetadata | undefined,
  exitCode: number | null,
  agentId?: string,
): WorkflowRunTransition {
  if (!workflow) {
    return {
      workflow: undefined,
      taskStatus: exitCode === 0 ? 'done' : 'blocked',
      phaseTransition: {
        outcome: 'unchanged',
      },
    };
  }

  const activeIndex = workflow.phases.findIndex((phase) => phase.status === 'in_progress');
  if (activeIndex < 0) {
    return {
      workflow,
      taskStatus: exitCode === 0 ? 'done' : 'blocked',
      phaseTransition: {
        outcome: 'unchanged',
      },
    };
  }

  const activePhase = workflow.phases[activeIndex];

  if (exitCode !== 0) {
    const blockedPhases = workflow.phases.map((phase, index) => (
      index === activeIndex ? { ...phase, status: 'blocked' as const } : phase
    ));

    return {
      workflow: { ...workflow, phases: blockedPhases },
      taskStatus: 'blocked',
      phaseTransition: {
        from: activePhase.label,
        to: activePhase.label,
        outcome: 'blocked',
      },
    };
  }

  const completedPhases = workflow.phases.map((phase, index) => (
    index === activeIndex ? { ...phase, status: 'done' as const } : phase
  ));
  const nextPendingIndex = completedPhases.findIndex((phase, index) => index > activeIndex && phase.status === 'pending');

  if (nextPendingIndex >= 0) {
    const nextPhase = completedPhases[nextPendingIndex];
    completedPhases[nextPendingIndex] = {
      ...nextPhase,
      status: 'in_progress',
    };

    return {
      workflow: {
        ...workflow,
        phases: completedPhases,
        lastCompletedPhaseId: activePhase.id,
        lastCompletedAgentId: agentId ?? workflow.lastCompletedAgentId,
      },
      taskStatus: 'in_progress',
      phaseTransition: {
        from: activePhase.label,
        to: nextPhase.label,
        outcome: 'advanced',
      },
    };
  }

  return {
    workflow: {
      ...workflow,
      phases: completedPhases,
      lastCompletedPhaseId: activePhase.id,
      lastCompletedAgentId: agentId ?? workflow.lastCompletedAgentId,
    },
    taskStatus: 'done',
    phaseTransition: {
      from: activePhase.label,
      outcome: 'completed',
    },
  };
}

export async function runTask(opts: RunTaskOptions): Promise<{ runId: string; exitCode: number | null }> {
  const db = await createDb();
  const runId = randomUUID();

  const [task] = await db.select().from(tasks).where(eq(tasks.id, opts.taskId));
  const [agent] = await db.select().from(agents).where(eq(agents.id, opts.agentId));
  if (!task || !agent) throw new Error('Task or agent not found');

  const [project] = await db.select().from(projects).where(eq(projects.id, task.projectId));
  if (!project) throw new Error('Project not found');

  const adapter = getAdapter(agent.adapterType);
  if (!adapter) throw new Error(`No adapter for type: ${agent.adapterType}`);

  const detected = await adapter.detect();
  if (!detected.installed) throw new Error(`${agent.adapterType} is not installed`);

  await db.update(tasks).set({ status: 'in_progress', agentId: opts.agentId, updatedAt: new Date() }).where(eq(tasks.id, opts.taskId));
  await db.update(agents).set({ status: 'running', lastHeartbeat: new Date() }).where(eq(agents.id, opts.agentId));

  const [run] = await db.insert(taskRuns).values({
    taskId: opts.taskId,
    agentId: opts.agentId,
    runId,
  }).returning();

  await db.insert(activityLog).values({
    projectId: project.id,
    agentId: agent.id,
    eventType: 'task.started',
    detail: {
      taskId: task.id,
      runId,
      title: task.title,
      execution: opts.executionEvidence,
    },
  });

  const logs: string[] = [];
  activeLogs.set(runId, logs);

  const cwd = project.path ?? process.cwd();
  const skills = await loadSkills(cwd);
  const skillNames = skills.map((s) => s.name).join(',');

  const env: Record<string, string> = {
    DDALKAK_AGENT_ID: agent.id,
    DDALKAK_API_URL: `http://${DEFAULT_HOST}:${DEFAULT_PORT}`,
    DDALKAK_RUN_ID: runId,
    DDALKAK_TASK_ID: task.id,
    DDALKAK_PROJECT_ID: project.id,
    ...(skillNames ? { DDALKAK_SKILLS: skillNames } : {}),
  };

  const workflow = (task.metadata as { workflow?: TaskWorkflowMetadata } | null | undefined)?.workflow;
  const workflowPrompt = workflow
    ? [
        `Workflow Template: ${workflow.name}${workflow.summary ? ` - ${workflow.summary}` : ''}`,
        workflow.phases.length > 0
          ? `Phases:\n${workflow.phases.map((phase, index) => `${index + 1}. ${phase.label}${phase.objective ? ` - ${phase.objective}` : ''}${phase.enforceSeparation ? ' (separate agent required)' : ''}`).join('\n')}`
          : undefined,
        workflow.checklist.length > 0
          ? `Checklist:\n${workflow.checklist.map((item) => `- ${item}`).join('\n')}`
          : undefined,
        workflow.separationMode === 'enforced'
          ? 'Separation Policy: review or verification phases must run in a separate agent/runtime context.'
          : undefined,
      ].filter(Boolean).join('\n\n')
    : undefined;

  const result = await adapter.execute({
    runId,
    prompt: [task.title, task.description, workflowPrompt].filter(Boolean).join('\n\n'),
    cwd,
    env,
    timeoutSec: opts.timeoutSec ?? 300,
    maxTurns: opts.maxTurns ?? 20,
    onLog: (stream, chunk) => {
      logs.push(`[${stream}] ${chunk}`);
      taskEvents.emit('log', { runId, stream, chunk } satisfies TaskLogEvent);
    },
  });

  await db.update(taskRuns).set({
    endedAt: new Date(),
    exitCode: result.exitCode,
    costUsd: result.costUsd ?? null,
    tokensIn: result.usage?.inputTokens ?? null,
    tokensOut: result.usage?.outputTokens ?? null,
  }).where(eq(taskRuns.id, run.id));

  const transition = applyWorkflowRunResult(workflow, result.exitCode, opts.agentId);
  const taskMetadata =
    task.metadata && typeof task.metadata === 'object' && !Array.isArray(task.metadata)
      ? task.metadata as Record<string, unknown>
      : {};

  await db.update(tasks).set({
    status: transition.taskStatus,
    metadata: transition.workflow ? { ...taskMetadata, workflow: transition.workflow } : taskMetadata,
    updatedAt: new Date(),
  }).where(eq(tasks.id, opts.taskId));
  await db.update(agents).set({ status: 'idle', lastHeartbeat: new Date() }).where(eq(agents.id, opts.agentId));

  await db.insert(activityLog).values({
    projectId: project.id,
    agentId: agent.id,
    eventType: result.exitCode === 0 ? 'task.completed' : 'task.failed',
    detail: {
      taskId: task.id,
      runId,
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      workflowPhase: transition.phaseTransition,
      execution: opts.executionEvidence,
    },
  });

  if (result.costUsd != null || result.usage != null) {
    const today = new Date().toISOString().slice(0, 10);
    await db.insert(costDaily).values({
      projectId: project.id,
      agentId: agent.id,
      date: today,
      totalUsd: result.costUsd ?? 0,
      tokensIn: result.usage?.inputTokens ?? 0,
      tokensOut: result.usage?.outputTokens ?? 0,
    }).onConflictDoUpdate({
      target: [costDaily.projectId, costDaily.agentId, costDaily.date],
      set: {
        totalUsd: sql`${costDaily.totalUsd} + excluded.total_usd`,
        tokensIn: sql`${costDaily.tokensIn} + excluded.tokens_in`,
        tokensOut: sql`${costDaily.tokensOut} + excluded.tokens_out`,
      },
    });
  }

  taskEvents.emit('done', { runId, exitCode: result.exitCode, timedOut: result.timedOut } satisfies TaskDoneEvent);

  setTimeout(() => activeLogs.delete(runId), 600_000);

  return { runId, exitCode: result.exitCode };
}
