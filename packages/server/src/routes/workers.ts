import { Router } from 'express';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';
import { heartbeatWorker, listWorkers, registerWorker } from '../services/worker-registry.service.js';

const registerWorkerSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  runtimeKind: z.enum(['local', 'remote']),
  adapterTypes: z.array(z.string().min(1)).min(1),
  capabilityLabels: z.array(z.string().min(1)).default([]),
  status: z.enum(['idle', 'busy', 'offline']).default('idle'),
  concurrency: z.number().int().positive().default(1),
});

export const workersRouter = Router();

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
