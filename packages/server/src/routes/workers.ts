import { Router } from 'express';
import { z } from 'zod';
import { createDb, activityLog } from '@ddalkak/db';
import { desc, sql } from 'drizzle-orm';
import { validate } from '../middleware/validation.js';
import { completeRun, getRunQueueItem, leaseNextQueuedRun, leaseRun, listRunQueueItems, type RunQueueItem } from '../services/run-queue.service.js';
import {
  canWorkerAcceptRun,
  getWorker,
  heartbeatWorker,
  listWorkers,
  markWorkerBusy,
  markWorkerIdle,
  registerWorker,
  type WorkerRegistration,
} from '../services/worker-registry.service.js';
import { buildExecutionEvidence, type ExecutionEvidence, WORKER_STALE_MS } from '../services/execution-evidence.service.js';

const registerWorkerSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  runtimeKind: z.enum(['local', 'remote']),
  adapterTypes: z.array(z.string().min(1)).min(1),
  capabilityLabels: z.array(z.string().min(1)).default([]),
  status: z.enum(['idle', 'busy', 'offline']).default('idle'),
  concurrency: z.number().int().positive().default(1),
});

const leaseWorkerSchema = z.object({
  queueId: z.string().min(1).optional(),
});

const completeRunSchema = z.object({
  state: z.enum(['completed', 'failed', 'cancelled']).optional(),
});

export const workersRouter = Router();
const HEARTBEAT_DEDUPE_WINDOW_MS = 5_000;

function includesAll(labels: string[], required: string[]) {
  return required.every((label) => labels.includes(label));
}

function canWorkerLeaseRun(workerId: string, queueId: string): { ok: true } | { ok: false; error: string; status: number } {
  const worker = getWorker(workerId);
  if (!worker) return { ok: false, error: 'Worker not found', status: 404 };

  const item = getRunQueueItem(queueId);
  if (!item) return { ok: false, error: 'Run request not found', status: 404 };
  if (item.state !== 'queued') return { ok: false, error: 'Run request is not queued', status: 409 };

  if (item.adapterType && !worker.adapterTypes.includes(item.adapterType)) {
    return { ok: false, error: 'Worker does not support the run adapter type', status: 409 };
  }
  if (!includesAll(worker.capabilityLabels, item.capabilityLabels ?? [])) {
    return { ok: false, error: 'Worker does not satisfy run capability labels', status: 409 };
  }
  return { ok: true };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function readExecutionDetail(detail: unknown): Record<string, unknown> | null {
  const base = asRecord(detail);
  if (!base) return null;
  const nested = asRecord(base.execution);
  return nested ?? base;
}

function readString(value: unknown) {
  return typeof value === 'string' ? value : null;
}

function readNumber(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function hasSameHeartbeatSnapshot(previousExecution: Record<string, unknown>, current: ExecutionEvidence) {
  return (
    readString(previousExecution.queueState) === current.queueState
    && (readNumber(previousExecution.queueAttempts) ?? 0) === current.queueAttempts
    && readString(previousExecution.workerStatus) === current.workerStatus
    && readString(previousExecution.workerHealth) === current.workerHealth
    && readString(previousExecution.workerCapacityLabel) === current.workerCapacityLabel
  );
}

function isWithinHeartbeatDedupeWindow(previousExecution: Record<string, unknown>, now = Date.now()) {
  const previousHeartbeat = readString(previousExecution.workerLastHeartbeat);
  if (!previousHeartbeat) return false;

  const previousHeartbeatMs = Date.parse(previousHeartbeat);
  if (!Number.isFinite(previousHeartbeatMs)) return false;

  const ageMs = now - previousHeartbeatMs;
  return ageMs >= 0 && ageMs < Math.min(WORKER_STALE_MS, HEARTBEAT_DEDUPE_WINDOW_MS);
}

async function shouldSkipHeartbeatActivity(db: Awaited<ReturnType<typeof createDb>>, queueItem: RunQueueItem, execution: ExecutionEvidence) {
  const latest = await db
    .select({ detail: activityLog.detail })
    .from(activityLog)
    .where(
      sql`${activityLog.eventType} = 'task.worker.heartbeat'
        AND ${activityLog.projectId} = ${queueItem.projectId}
        AND ${activityLog.detail}->>'taskId' = ${queueItem.taskId}
        AND ${activityLog.detail}->>'queueId' = ${queueItem.id}`,
    )
    .orderBy(desc(activityLog.createdAt))
    .limit(1);

  const previousExecution = latest[0] ? readExecutionDetail(latest[0].detail) : null;
  if (!previousExecution) return false;
  if (!hasSameHeartbeatSnapshot(previousExecution, execution)) return false;
  if (!isWithinHeartbeatDedupeWindow(previousExecution)) return false;
  return true;
}

async function logTaskWorkerActivity(
  eventType: string,
  queueItem: RunQueueItem,
  worker: WorkerRegistration | null | undefined,
  waitReason?: string,
  opts?: { dedupeHeartbeat?: boolean },
) {
  const db = await createDb();
  const execution = buildExecutionEvidence({
    dispatchMode: 'remote-queued',
    queueItem,
    worker,
    waitReason,
  });

  if (eventType === 'task.worker.heartbeat' && opts?.dedupeHeartbeat) {
    const shouldSkip = await shouldSkipHeartbeatActivity(db, queueItem, execution);
    if (shouldSkip) return;
  }

  await db.insert(activityLog).values({
    projectId: queueItem.projectId,
    agentId: queueItem.agentId,
    eventType,
    detail: {
      taskId: queueItem.taskId,
      queueId: queueItem.id,
      execution,
    },
  });
}

workersRouter.get('/', (_req, res) => {
  res.json({ ok: true, data: listWorkers() });
});

workersRouter.post('/register', validate(registerWorkerSchema), (req, res) => {
  const worker = registerWorker(req.body);
  res.status(201).json({ ok: true, data: worker });
});

workersRouter.post('/:id/heartbeat', async (req, res) => {
  const worker = heartbeatWorker(req.params.id);
  if (!worker) {
    res.status(404).json({ ok: false, error: 'Worker not found' });
    return;
  }

  const activeRuns = listRunQueueItems().filter((item) => item.workerId === worker.id && (item.state === 'leased' || item.state === 'running'));
  await Promise.all(activeRuns.map((item) => logTaskWorkerActivity('task.worker.heartbeat', item, worker, undefined, { dedupeHeartbeat: true })));

  res.json({ ok: true, data: worker });
});

workersRouter.post('/:id/lease', validate(leaseWorkerSchema), async (req, res) => {
  const workerId = req.params.id as string;
  const worker = getWorker(workerId);
  if (!worker) {
    res.status(404).json({ ok: false, error: 'Worker not found' });
    return;
  }
  if (!canWorkerAcceptRun(worker.id)) {
    const queueId = req.body.queueId as string | undefined;
    if (queueId) {
      const queueItem = getRunQueueItem(queueId);
      if (queueItem) {
        await logTaskWorkerActivity(
          'task.worker.capacity_blocked',
          queueItem,
          worker,
          'worker has no available capacity',
        );
      }
    }
    res.status(409).json({ ok: false, error: 'Worker has no available capacity' });
    return;
  }

  const queueId = req.body.queueId as string | undefined;
  let leased = null;

  if (queueId) {
    const validation = canWorkerLeaseRun(worker.id, queueId);
    if (!validation.ok) {
      res.status(validation.status).json({ ok: false, error: validation.error });
      return;
    }
    leased = leaseRun(queueId, worker.id);
  } else {
    leased = leaseNextQueuedRun(worker.id, {
      adapterTypes: worker.adapterTypes,
      capabilityLabels: worker.capabilityLabels,
    });
  }

  if (!leased) {
    res.status(404).json({ ok: false, error: 'No queued run available for this worker' });
    return;
  }

  markWorkerBusy(worker.id);
  const busyWorker = getWorker(worker.id) ?? worker;
  await logTaskWorkerActivity('task.worker.leased', leased, busyWorker);
  res.json({ ok: true, data: leased });
});

workersRouter.post('/:id/runs/:runRequestId/complete', validate(completeRunSchema), async (req, res) => {
  const workerId = req.params.id as string;
  const runRequestId = req.params.runRequestId as string;
  const worker = getWorker(workerId);
  if (!worker) {
    res.status(404).json({ ok: false, error: 'Worker not found' });
    return;
  }

  const run = getRunQueueItem(runRequestId);
  if (!run) {
    res.status(404).json({ ok: false, error: 'Run request not found' });
    return;
  }
  if (run.workerId !== worker.id) {
    res.status(409).json({ ok: false, error: 'Run request is leased by another worker' });
    return;
  }

  const state = req.body.state ?? 'completed';
  const completed = completeRun(run.id, state);
  if (!completed) {
    res.status(409).json({ ok: false, error: 'Run request is not in a completable state' });
    return;
  }

  markWorkerIdle(worker.id);
  const idleWorker = getWorker(worker.id) ?? worker;
  await logTaskWorkerActivity(`task.worker.${state}`, completed, idleWorker);
  res.json({ ok: true, data: completed });
});

workersRouter.post('/:id/runs/:runRequestId/fail', async (req, res) => {
  const workerId = req.params.id as string;
  const runRequestId = req.params.runRequestId as string;
  const worker = getWorker(workerId);
  if (!worker) {
    res.status(404).json({ ok: false, error: 'Worker not found' });
    return;
  }

  const run = getRunQueueItem(runRequestId);
  if (!run) {
    res.status(404).json({ ok: false, error: 'Run request not found' });
    return;
  }
  if (run.workerId !== worker.id) {
    res.status(409).json({ ok: false, error: 'Run request is leased by another worker' });
    return;
  }

  const completed = completeRun(run.id, 'failed');
  if (!completed) {
    res.status(409).json({ ok: false, error: 'Run request is not in a completable state' });
    return;
  }

  markWorkerIdle(worker.id);
  const idleWorker = getWorker(worker.id) ?? worker;
  await logTaskWorkerActivity('task.worker.failed', completed, idleWorker);
  res.json({ ok: true, data: completed });
});
