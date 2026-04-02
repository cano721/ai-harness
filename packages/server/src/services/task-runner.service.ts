import { randomUUID } from 'crypto';
import { EventEmitter } from 'events';
import { createDb, tasks, agents, taskRuns, activityLog, projects, costDaily } from '@ddalkak/db';
import { eq, sql } from 'drizzle-orm';
import { getAdapter } from '../adapters/index.js';
import { DEFAULT_PORT, DEFAULT_HOST } from '@ddalkak/shared';
import { loadSkills } from './skill-loader.service.js';

interface RunTaskOptions {
  taskId: string;
  agentId: string;
  timeoutSec?: number;
  maxTurns?: number;
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

export const taskEvents = new EventEmitter();
taskEvents.setMaxListeners(100);

const activeLogs = new Map<string, string[]>();

export function getRunLogs(runId: string): string[] {
  return activeLogs.get(runId) ?? [];
}

export function isRunActive(runId: string): boolean {
  return activeLogs.has(runId);
}

export async function runTask(opts: RunTaskOptions): Promise<{ runId: string; exitCode: number | null }> {
  const db = await createDb();
  const runId = randomUUID();

  // Get task, agent, project
  const [task] = await db.select().from(tasks).where(eq(tasks.id, opts.taskId));
  const [agent] = await db.select().from(agents).where(eq(agents.id, opts.agentId));
  if (!task || !agent) throw new Error('Task or agent not found');

  const [project] = await db.select().from(projects).where(eq(projects.id, task.projectId));
  if (!project) throw new Error('Project not found');

  const adapter = getAdapter(agent.adapterType);
  if (!adapter) throw new Error(`No adapter for type: ${agent.adapterType}`);

  const detected = await adapter.detect();
  if (!detected.installed) throw new Error(`${agent.adapterType} is not installed`);

  // Update statuses
  await db.update(tasks).set({ status: 'in_progress', agentId: opts.agentId, updatedAt: new Date() }).where(eq(tasks.id, opts.taskId));
  await db.update(agents).set({ status: 'running', lastHeartbeat: new Date() }).where(eq(agents.id, opts.agentId));

  // Create task run record
  const [run] = await db.insert(taskRuns).values({
    taskId: opts.taskId,
    agentId: opts.agentId,
    runId,
  }).returning();

  // Log activity
  await db.insert(activityLog).values({
    projectId: project.id,
    agentId: agent.id,
    eventType: 'task.started',
    detail: { taskId: task.id, runId, title: task.title },
  });

  // Collect logs
  const logs: string[] = [];
  activeLogs.set(runId, logs);

  // Build env
  const cwd = project.path ?? process.cwd();

  const skills = await loadSkills(cwd);
  const skillNames = skills.map(s => s.name).join(',');

  const env: Record<string, string> = {
    DDALKAK_AGENT_ID: agent.id,
    DDALKAK_API_URL: `http://${DEFAULT_HOST}:${DEFAULT_PORT}`,
    DDALKAK_RUN_ID: runId,
    DDALKAK_TASK_ID: task.id,
    DDALKAK_PROJECT_ID: project.id,
    ...(skillNames ? { DDALKAK_SKILLS: skillNames } : {}),
  };

  // Execute
  const result = await adapter.execute({
    runId,
    prompt: task.description ? `${task.title}\n\n${task.description}` : task.title,
    cwd,
    env,
    timeoutSec: opts.timeoutSec ?? 300,
    maxTurns: opts.maxTurns ?? 20,
    onLog: (stream, chunk) => {
      logs.push(`[${stream}] ${chunk}`);
      taskEvents.emit('log', { runId, stream, chunk } satisfies TaskLogEvent);
    },
  });

  // Update records
  await db.update(taskRuns).set({
    endedAt: new Date(),
    exitCode: result.exitCode,
    costUsd: result.costUsd ?? null,
    tokensIn: result.usage?.inputTokens ?? null,
    tokensOut: result.usage?.outputTokens ?? null,
  }).where(eq(taskRuns.id, run.id));

  const taskStatus = result.exitCode === 0 ? 'done' : 'blocked';
  await db.update(tasks).set({ status: taskStatus, updatedAt: new Date() }).where(eq(tasks.id, opts.taskId));
  await db.update(agents).set({ status: 'idle', lastHeartbeat: new Date() }).where(eq(agents.id, opts.agentId));

  await db.insert(activityLog).values({
    projectId: project.id,
    agentId: agent.id,
    eventType: result.exitCode === 0 ? 'task.completed' : 'task.failed',
    detail: { taskId: task.id, runId, exitCode: result.exitCode, timedOut: result.timedOut },
  });

  // Upsert cost daily — accumulate same date+agent+project
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

  // Emit done event for SSE subscribers
  taskEvents.emit('done', { runId, exitCode: result.exitCode, timedOut: result.timedOut } satisfies TaskDoneEvent);

  // Cleanup logs after 10 minutes
  setTimeout(() => activeLogs.delete(runId), 600_000);

  return { runId, exitCode: result.exitCode };
}
