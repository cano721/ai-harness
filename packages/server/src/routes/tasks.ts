import { Router } from 'express';
import { createDb, tasks, taskRuns } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import { runTask, getRunLogs } from '../services/task-runner.service.js';

export const tasksRouter = Router();

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
  const [task] = await db.select().from(tasks).where(eq(tasks.id, req.params.id));
  if (!task) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }
  res.json({ ok: true, data: task });
});

// Create task
tasksRouter.post('/', async (req, res) => {
  const db = await createDb();
  const { projectId, title, description, agentId } = req.body;
  const [created] = await db.insert(tasks).values({
    projectId,
    title,
    description,
    agentId: agentId ?? null,
  }).returning();
  res.status(201).json({ ok: true, data: created });
});

// Update task
tasksRouter.patch('/:id', async (req, res) => {
  const db = await createDb();
  const updates: Record<string, unknown> = { updatedAt: new Date() };
  if (req.body.title !== undefined) updates.title = req.body.title;
  if (req.body.description !== undefined) updates.description = req.body.description;
  if (req.body.status !== undefined) updates.status = req.body.status;
  if (req.body.agentId !== undefined) updates.agentId = req.body.agentId;

  const [result] = await db.update(tasks).set(updates).where(eq(tasks.id, req.params.id)).returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

// Atomic checkout (assign agent to task)
tasksRouter.post('/:id/checkout', async (req, res) => {
  const db = await createDb();
  const { agentId } = req.body;

  const [task] = await db.select().from(tasks).where(eq(tasks.id, req.params.id));
  if (!task) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }
  if (task.status === 'in_progress' && task.agentId) {
    res.status(409).json({ ok: false, error: 'Task already checked out' });
    return;
  }

  const [updated] = await db.update(tasks)
    .set({ agentId, status: 'in_progress', updatedAt: new Date() })
    .where(eq(tasks.id, req.params.id))
    .returning();

  res.json({ ok: true, data: updated });
});

// Run task (execute agent)
tasksRouter.post('/:id/run', async (req, res) => {
  const db = await createDb();
  const [task] = await db.select().from(tasks).where(eq(tasks.id, req.params.id));
  if (!task) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }

  const agentId = req.body.agentId ?? task.agentId;
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
