import { Router } from 'express';
import { getAgentMetrics, getProjectMetrics, getSystemMetrics } from '../services/metrics.service.js';

export const metricsRouter = Router();

metricsRouter.get('/agents', async (_req, res) => {
  const data = await getAgentMetrics();
  res.json({ ok: true, data });
});

metricsRouter.get('/projects', async (_req, res) => {
  const data = await getProjectMetrics();
  res.json({ ok: true, data });
});

metricsRouter.get('/system', async (_req, res) => {
  const data = await getSystemMetrics();
  res.json({ ok: true, data });
});
