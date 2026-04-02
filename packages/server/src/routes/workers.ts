import { Router } from 'express';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';
import { completeRun, getRunQueueItem, leaseNextQueuedRun, leaseRun } from '../services/run-queue.service.js';
import {
  canWorkerAcceptRun,
  getWorker,
  heartbeatWorker,
  listWorkers,
  markWorkerBusy,
  markWorkerIdle,
  registerWorker,
} from '../services/worker-registry.service.js';

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

workersRouter.get('/', (_req, res) => {
  res.json({ ok: true, data: listWorkers() });
});

workersRouter.post('/register', validate(registerWorkerSchema), (req, res) => {
  const worker = registerWorker(req.body);
  res.status(201).json({ ok: true, data: worker });
});

workersRouter.post('/:id/heartbeat', (req, res) => {
  const worker = heartbeatWorker(req.params.id);
  if (!worker) {
    res.status(404).json({ ok: false, error: 'Worker not found' });
    return;
  }
  res.json({ ok: true, data: worker });
});

workersRouter.post('/:id/lease', validate(leaseWorkerSchema), (req, res) => {
  const workerId = req.params.id as string;
  const worker = getWorker(workerId);
  if (!worker) {
    res.status(404).json({ ok: false, error: 'Worker not found' });
    return;
  }
  if (!canWorkerAcceptRun(worker.id)) {
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
  res.json({ ok: true, data: leased });
});

workersRouter.post('/:id/runs/:runRequestId/complete', validate(completeRunSchema), (req, res) => {
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
  res.json({ ok: true, data: completed });
});

workersRouter.post('/:id/runs/:runRequestId/fail', (req, res) => {
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
  res.json({ ok: true, data: completed });
});
