import { randomUUID } from 'crypto';
import { createDb, tasks, agents, taskRuns, activityLog, projects } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import { getAdapter } from '../adapters/index.js';
import { DEFAULT_PORT, DEFAULT_HOST } from '@ddalkak/shared';

interface RunTaskOptions {
  taskId: string;
  agentId: string;
  timeoutSec?: number;
  maxTurns?: number;
}

const activeLogs = new Map<string, string[]>();

export function getRunLogs(runId: string): string[] {
  return activeLogs.get(runId) ?? [];
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
  const env: Record<string, string> = {
    DDALKAK_AGENT_ID: agent.id,
    DDALKAK_API_URL: `http://${DEFAULT_HOST}:${DEFAULT_PORT}`,
    DDALKAK_RUN_ID: runId,
    DDALKAK_TASK_ID: task.id,
    DDALKAK_PROJECT_ID: project.id,
  };

  const cwd = project.path ?? process.cwd();

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

  // Cleanup logs after 10 minutes
  setTimeout(() => activeLogs.delete(runId), 600_000);

  return { runId, exitCode: result.exitCode };
}
