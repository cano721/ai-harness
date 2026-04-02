import { Router } from 'express';
import { createDb, tasks, taskRuns, agents } from '@ddalkak/db';
import { eq, and, ne } from 'drizzle-orm';
import { runTask, getRunLogs, isRunActive, taskEvents, type TaskLogEvent, type TaskDoneEvent } from '../services/task-runner.service.js';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';

const createTaskSchema = z.object({
  projectId: z.string().min(1, 'projectId is required'),
  title: z.string().min(1, 'title is required'),
  description: z.string().optional(),
  agentId: z.string().optional().nullable(),
  metadata: z.object({
    workflow: z.object({
      id: z.string().min(1),
      name: z.string().min(1),
      summary: z.string().optional(),
      source: z.literal('gear'),
      separationMode: z.enum(['advisory', 'enforced']),
      lastCompletedPhaseId: z.string().optional(),
      lastCompletedAgentId: z.string().optional(),
      lastBlockedReason: z.string().optional(),
      phases: z.array(z.object({
        id: z.string().min(1),
        label: z.string().min(1),
        objective: z.string().optional(),
        enforceSeparation: z.boolean().optional(),
        status: z.enum(['pending', 'in_progress', 'done', 'blocked']).optional(),
      })).default([]),
      checklist: z.array(z.string().min(1)).default([]),
    }).optional(),
  }).optional(),
});

const updateTaskSchema = z.object({
  title: z.string().min(1).optional(),
  description: z.string().optional(),
  status: z.string().optional(),
  agentId: z.string().optional().nullable(),
  metadata: z.object({
    workflow: z.object({
      id: z.string().min(1),
      name: z.string().min(1),
      summary: z.string().optional(),
      source: z.literal('gear'),
      separationMode: z.enum(['advisory', 'enforced']),
      lastCompletedPhaseId: z.string().optional(),
      lastCompletedAgentId: z.string().optional(),
      lastBlockedReason: z.string().optional(),
      phases: z.array(z.object({
        id: z.string().min(1),
        label: z.string().min(1),
        objective: z.string().optional(),
        enforceSeparation: z.boolean().optional(),
        status: z.enum(['pending', 'in_progress', 'done', 'blocked']).optional(),
      })).default([]),
      checklist: z.array(z.string().min(1)).default([]),
    }).optional(),
  }).optional(),
});

export const tasksRouter = Router();

async function pickReviewAgent(task: { projectId: string }, lastCompletedAgentId?: string) {
  const db = await createDb();
  const projectAgents = await db
    .select()
    .from(agents)
    .where(and(eq(agents.projectId, task.projectId), eq(agents.status, 'idle')));

  const candidates = lastCompletedAgentId
    ? projectAgents.filter((agent) => agent.id !== lastCompletedAgentId)
    : projectAgents;
  const reviewer = candidates.find((agent) => /review/i.test(agent.name));
  return reviewer ?? candidates[0] ?? null;
}

// List tasks (optionally by project)
tasksRouter.get('/', async (req, res) => {
  const db = await createDb();
  const projectId = req.query.projectId as string | undefined;
  const result = projectId
    ? await db.select().from(tasks).where(eq(tasks.projectId, projectId))
    : await db.select().from(tasks);
  res.json({ ok: true, data: result });
});

// Get single task
tasksRouter.get('/:id', async (req, res) => {
  const db = await createDb();
  const [task] = await db.select().from(tasks).where(eq(tasks.id, req.params.id as string));
  if (!task) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }
  res.json({ ok: true, data: task });
});

// Create task
tasksRouter.post('/', validate(createTaskSchema), async (req, res) => {
  const db = await createDb();
  const { projectId, title, description, agentId, metadata } = req.body;
  const [created] = await db.insert(tasks).values({
    projectId,
    title,
    description,
    metadata: metadata ?? {},
    agentId: agentId ?? null,
  }).returning();
  res.status(201).json({ ok: true, data: created });
});

// Update task
tasksRouter.patch('/:id', validate(updateTaskSchema), async (req, res) => {
  const db = await createDb();
  const updates: Record<string, unknown> = { updatedAt: new Date() };
  if (req.body.title !== undefined) updates.title = req.body.title;
  if (req.body.description !== undefined) updates.description = req.body.description;
  if (req.body.status !== undefined) updates.status = req.body.status;
  if (req.body.agentId !== undefined) updates.agentId = req.body.agentId;
  if (req.body.metadata !== undefined) updates.metadata = req.body.metadata;

  const [result] = await db.update(tasks).set(updates).where(eq(tasks.id, req.params.id as string)).returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

// Atomic checkout (assign agent to task)
tasksRouter.post('/:id/checkout', async (req, res) => {
  const db = await createDb();
  let { agentId } = req.body;

  const result = await db.transaction(async (tx) => {
    const [task] = await tx.select().from(tasks).where(eq(tasks.id, req.params.id as string));
    if (!task) return { error: 'Task not found', status: 404 };
    if (task.status === 'in_progress' && task.agentId) {
      return { error: 'Task already checked out', status: 409 };
    }

    // Auto-route: if no agentId provided, pick an idle agent in the same project
    if (!agentId) {
      const [idleAgent] = await tx
        .select()
        .from(agents)
        .where(and(eq(agents.projectId, task.projectId), eq(agents.status, 'idle')));
      if (!idleAgent) {
        return { error: 'No idle agent available in project', status: 400 };
      }
      agentId = idleAgent.id;
    }

    const [updated] = await tx
      .update(tasks)
      .set({ agentId, status: 'in_progress', updatedAt: new Date() })
      .where(eq(tasks.id, req.params.id as string))
      .returning();

    if (!updated) {
      return { error: 'Task already checked out', status: 409 };
    }

    return { data: updated };
  });

  if ('error' in result) {
    res.status(result.status ?? 500).json({ ok: false, error: result.error });
    return;
  }
  res.json({ ok: true, data: result.data });
});

// Run task (execute agent)
tasksRouter.post('/:id/run', async (req, res) => {
  const db = await createDb();
  const [task] = await db.select().from(tasks).where(eq(tasks.id, req.params.id as string));
  if (!task) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }

  const workflow = (task.metadata as {
    workflow?: {
      lastCompletedAgentId?: string;
      phases?: Array<{ status?: string; enforceSeparation?: boolean }>;
    };
  } | null | undefined)?.workflow;
  const activePhase = workflow?.phases?.find((phase) => phase.status === 'in_progress');
  const requestedAgentId = req.body.agentId ?? task.agentId;
  let agentId = requestedAgentId;

  if (activePhase?.enforceSeparation) {
    if (req.body.agentId && workflow?.lastCompletedAgentId === req.body.agentId) {
      res.status(409).json({ ok: false, error: 'Separation policy requires a different agent for the active review phase' });
      return;
    }

    if (!agentId || workflow?.lastCompletedAgentId === agentId) {
      const reviewAgent = await pickReviewAgent(task, workflow?.lastCompletedAgentId);
      if (!reviewAgent) {
        const blockedWorkflow = workflow
          ? {
              ...workflow,
              lastBlockedReason: 'No idle reviewer agent available for the active review phase.',
              phases: (workflow.phases ?? []).map((phase) => (
                phase.status === 'in_progress' ? { ...phase, status: 'blocked' } : phase
              )),
            }
          : workflow;

        await db.update(tasks).set({
          status: 'blocked',
          metadata: blockedWorkflow ? { ...(task.metadata as Record<string, unknown>), workflow: blockedWorkflow } : task.metadata,
          updatedAt: new Date(),
        }).where(eq(tasks.id, req.params.id as string));
        res.status(409).json({ ok: false, error: 'Separation policy requires an idle reviewer agent for the active review phase' });
        return;
      }
      agentId = reviewAgent.id;
    }
  }

  if (!agentId) {
    res.status(400).json({ ok: false, error: 'No agent assigned' });
    return;
  }

  // Run async - return immediately with runId
  const timeoutSec = req.body.timeoutSec ?? 300;
  const maxTurns = req.body.maxTurns ?? 20;

  // Start task in background
  runTask({ taskId: task.id, agentId, timeoutSec, maxTurns })
    .catch((err) => console.error('Task run error:', err));

  res.json({ ok: true, data: { taskId: task.id, agentId, status: 'started' } });
});

// Get task run history
tasksRouter.get('/:id/runs', async (req, res) => {
  const db = await createDb();
  const result = await db.select().from(taskRuns).where(eq(taskRuns.taskId, req.params.id));
  res.json({ ok: true, data: result });
});

// Get run logs
tasksRouter.get('/runs/:runId/logs', async (req, res) => {
  const logs = getRunLogs(req.params.runId);
  res.json({ ok: true, data: logs });
});

// SSE: stream live logs for a run
tasksRouter.get('/runs/:runId/stream', (req, res) => {
  const { runId } = req.params;

  const existingLogs = getRunLogs(runId);
  const active = isRunActive(runId);

  if (!active && existingLogs.length === 0) {
    res.status(404).json({ ok: false, error: 'Run not found' });
    return;
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  const sendEvent = (event: string, data: unknown) => {
    res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };

  // Replay buffered logs
  for (const line of existingLogs) {
    sendEvent('log', { line });
  }

  // If already done (not active), close immediately
  if (!active) {
    sendEvent('done', { runId, exitCode: null, timedOut: false });
    res.end();
    return;
  }

  const onLog = (evt: TaskLogEvent) => {
    if (evt.runId !== runId) return;
    sendEvent('log', { stream: evt.stream, chunk: evt.chunk });
  };

  const onDone = (evt: TaskDoneEvent) => {
    if (evt.runId !== runId) return;
    sendEvent('done', { runId: evt.runId, exitCode: evt.exitCode, timedOut: evt.timedOut });
    cleanup();
    res.end();
  };

  const cleanup = () => {
    taskEvents.off('log', onLog);
    taskEvents.off('done', onDone);
  };

  taskEvents.on('log', onLog);
  taskEvents.on('done', onDone);

  req.on('close', cleanup);
});
