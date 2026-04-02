import { Router } from 'express';
import { createDb, tasks, taskRuns, agents, activityLog } from '@ddalkak/db';
import { eq, and, ne } from 'drizzle-orm';
import { runTask, getRunLogs, isRunActive, taskEvents, type TaskLogEvent, type TaskDoneEvent } from '../services/task-runner.service.js';
import { dispatchTaskRun } from '../services/task-dispatcher.service.js';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';

const checklistEntrySchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  kind: z.enum(['required', 'advisory', 'evidence']),
});

const checklistEntryArraySchema = z.array(z.union([z.string().min(1), checklistEntrySchema]));

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
      phaseChecklistMap: z.record(z.string(), checklistEntryArraySchema).optional(),
      completedChecklist: z.array(z.string().min(1)).optional(),
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
      phaseChecklistMap: z.record(z.string(), checklistEntryArraySchema).optional(),
      completedChecklist: z.array(z.string().min(1)).optional(),
    }).optional(),
  }).optional(),
});

export const tasksRouter = Router();

type ChecklistEntry = string | { id: string; label: string; kind: 'required' | 'advisory' | 'evidence' };

function normalizeChecklistEntry(entry: ChecklistEntry) {
  if (typeof entry === 'string') {
    return { id: entry, label: entry, kind: 'required' as const };
  }
  return entry;
}

function getChecklistToggleEvent(
  task: { id: string; projectId: string; agentId: string | null; metadata?: unknown },
  nextMetadata: unknown,
) {
  const currentWorkflow = (task.metadata as {
    workflow?: {
      id?: string;
      name?: string;
      phases?: Array<{ label?: string; status?: string }>;
      phaseChecklistMap?: Record<string, ChecklistEntry[]>;
      completedChecklist?: string[];
    };
  } | null | undefined)?.workflow;
  const nextWorkflow = (nextMetadata as {
    workflow?: {
      id?: string;
      name?: string;
      phases?: Array<{ label?: string; status?: string }>;
      phaseChecklistMap?: Record<string, ChecklistEntry[]>;
      completedChecklist?: string[];
    };
  } | null | undefined)?.workflow;

  if (!currentWorkflow || !nextWorkflow) return null;

  const previous = new Set(currentWorkflow.completedChecklist ?? []);
  const next = new Set(nextWorkflow.completedChecklist ?? []);
  const completedItem = [...next].find((item) => !previous.has(item));
  const reopenedItem = [...previous].find((item) => !next.has(item));
  const checklistItemId = completedItem ?? reopenedItem;

  if (!checklistItemId) return null;

  const checklistEntries = Object.values(nextWorkflow.phaseChecklistMap ?? {}).flat().map(normalizeChecklistEntry);
  const matchedEntry = checklistEntries.find((entry) => entry.id === checklistItemId || entry.label === checklistItemId);

  const activePhase = nextWorkflow.phases?.find((phase) => phase.status === 'in_progress' || phase.status === 'blocked');
  const phaseLabel = activePhase?.label ?? 'Checklist';

  return {
    projectId: task.projectId,
    agentId: task.agentId,
    eventType: 'task.checklist.toggled',
    detail: {
      taskId: task.id,
      workflowId: nextWorkflow.id,
      workflowName: nextWorkflow.name,
      checklistItem: matchedEntry?.label ?? checklistItemId,
      checklistItemId,
      checklistKind: matchedEntry?.kind ?? 'required',
      state: completedItem ? 'completed' : 'reopened',
      workflowPhase: {
        from: phaseLabel,
        to: phaseLabel,
        outcome: completedItem ? 'completed' : 'unchanged',
      },
    },
  };
}

function getWorkflowTransitionBlock(
  currentMetadata: unknown,
  nextMetadata: unknown,
) {
  const currentWorkflow = (currentMetadata as {
    workflow?: {
      phases?: Array<{ id?: string; label?: string; status?: string }>;
      checklist?: string[];
      phaseChecklistMap?: Record<string, ChecklistEntry[]>;
      completedChecklist?: string[];
    };
  } | null | undefined)?.workflow;
  const nextWorkflow = (nextMetadata as {
    workflow?: {
      phases?: Array<{ id?: string; label?: string; status?: string }>;
      checklist?: string[];
      phaseChecklistMap?: Record<string, ChecklistEntry[]>;
      completedChecklist?: string[];
    };
  } | null | undefined)?.workflow;

  if (!currentWorkflow || !nextWorkflow) return null;

  const currentActivePhase = currentWorkflow.phases?.find((phase) => phase.status === 'in_progress');
  if (!currentActivePhase?.id) return null;

  const nextSamePhase = nextWorkflow.phases?.find((phase) => phase.id === currentActivePhase.id);
  if (!nextSamePhase || nextSamePhase.status === 'in_progress' || nextSamePhase.status === 'blocked') return null;

  const phaseScopedEntries = nextWorkflow.phaseChecklistMap?.[currentActivePhase.id]
    ?? currentWorkflow.phaseChecklistMap?.[currentActivePhase.id];
  const checklistEntries = (phaseScopedEntries?.length ? phaseScopedEntries : (nextWorkflow.checklist ?? currentWorkflow.checklist ?? []))
    .map(normalizeChecklistEntry);
  const remainingRequired = checklistEntries.filter((entry) => (
    entry.kind === 'required'
    && !(nextWorkflow.completedChecklist ?? []).includes(entry.id)
    && !(nextWorkflow.completedChecklist ?? []).includes(entry.label)
  ));

  if (remainingRequired.length === 0) return null;

  return {
    phaseId: currentActivePhase.id,
    phaseLabel: currentActivePhase.label ?? currentActivePhase.id,
    remainingRequired,
  };
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
  const [existingTask] = await db.select().from(tasks).where(eq(tasks.id, req.params.id as string));
  if (!existingTask) {
    res.status(404).json({ ok: false, error: 'Task not found' });
    return;
  }

  const workflowTransitionBlock = req.body.metadata !== undefined
    ? getWorkflowTransitionBlock(existingTask.metadata, req.body.metadata)
    : null;

  if (workflowTransitionBlock) {
    res.status(409).json({
      ok: false,
      error: `Complete required checklist items before leaving ${workflowTransitionBlock.phaseLabel}: ${workflowTransitionBlock.remainingRequired.map((entry) => entry.label).join(', ')}`,
      data: {
        phaseId: workflowTransitionBlock.phaseId,
        phaseLabel: workflowTransitionBlock.phaseLabel,
        requiredItems: workflowTransitionBlock.remainingRequired,
      },
    });
    return;
  }

  const updates: Record<string, unknown> = { updatedAt: new Date() };
  if (req.body.title !== undefined) updates.title = req.body.title;
  if (req.body.description !== undefined) updates.description = req.body.description;
  if (req.body.status !== undefined) updates.status = req.body.status;
  if (req.body.agentId !== undefined) updates.agentId = req.body.agentId;
  if (req.body.metadata !== undefined) updates.metadata = req.body.metadata;

  const [result] = await db.update(tasks).set(updates).where(eq(tasks.id, req.params.id as string)).returning();
  const checklistEvent = req.body.metadata !== undefined
    ? getChecklistToggleEvent(existingTask, req.body.metadata)
    : null;

  if (result && checklistEvent) {
    await db.insert(activityLog).values({
      ...checklistEvent,
      agentId: req.body.agentId ?? checklistEvent.agentId ?? null,
    });
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

  const dispatchMode = req.body?.dispatchMode;
  if (dispatchMode && dispatchMode !== 'local-inline' && dispatchMode !== 'remote-queued') {
    res.status(400).json({ ok: false, error: 'Invalid dispatchMode' });
    return;
  }

  const dispatch = await dispatchTaskRun({
    task: {
      id: task.id,
      projectId: task.projectId,
      agentId: task.agentId,
      metadata: task.metadata,
    },
    requestedAgentId: req.body?.agentId,
    dispatchMode,
    timeoutSec: req.body?.timeoutSec ?? 300,
    maxTurns: req.body?.maxTurns ?? 20,
  });

  if (!dispatch.ok) {
    res.status(dispatch.status).json({ ok: false, error: dispatch.error });
    return;
  }

  res.json({
    ok: true,
    data: {
      taskId: task.id,
      agentId: dispatch.agentId,
      status: dispatch.status,
      dispatchMode: dispatch.dispatchMode,
      queueState: dispatch.queueState,
      queueId: dispatch.queueId,
      workerId: dispatch.workerId,
    },
  });
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
