import { Router } from 'express';
import { createDb, agents, tasks } from '@ddalkak/db';
import { eq, and } from 'drizzle-orm';
import type { ApiResponse } from '@ddalkak/shared';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';

const createAgentSchema = z.object({
  projectId: z.string().min(1, 'projectId is required'),
  name: z.string().min(1, 'name is required'),
  adapterType: z.string().min(1, 'adapterType is required'),
  config: z.record(z.string(), z.unknown()).optional(),
});

const updateAgentSchema = z.object({
  name: z.string().min(1).optional(),
  config: z.record(z.string(), z.unknown()).optional(),
  status: z.string().optional(),
});

export const agentsRouter = Router();

agentsRouter.get('/', async (_req, res) => {
  const db = await createDb();
  const result = await db.select().from(agents);
  res.json({ ok: true, data: result } satisfies ApiResponse);
});

agentsRouter.get('/me', async (req, res) => {
  const agentId = req.headers['x-ddalkak-agent-id'] ?? req.headers['ddalkak-agent-id'];
  if (!agentId || typeof agentId !== 'string') {
    res.status(401).json({ ok: false, error: 'Missing agent id header' });
    return;
  }
  const db = await createDb();
  const [result] = await db.select().from(agents).where(eq(agents.id, agentId));
  if (!result) {
    res.status(404).json({ ok: false, error: 'Agent not found' });
    return;
  }
  res.json({ ok: true, data: result } satisfies ApiResponse);
});

agentsRouter.get('/me/inbox', async (req, res) => {
  const agentId = req.headers['x-ddalkak-agent-id'] ?? req.headers['ddalkak-agent-id'];
  if (!agentId || typeof agentId !== 'string') {
    res.status(401).json({ ok: false, error: 'Missing agent id header' });
    return;
  }
  const db = await createDb();
  const [agent] = await db.select().from(agents).where(eq(agents.id, agentId));
  if (!agent) {
    res.status(404).json({ ok: false, error: 'Agent not found' });
    return;
  }
  const inbox = await db.select().from(tasks).where(
    and(eq(tasks.agentId, agentId), eq(tasks.status, 'todo'))
  );
  res.json({ ok: true, data: inbox } satisfies ApiResponse);
});

agentsRouter.get('/:id', async (req, res) => {
  const db = await createDb();
  const [result] = await db.select().from(agents).where(eq(agents.id, req.params.id));
  if (!result) {
    res.status(404).json({ ok: false, error: 'Agent not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

agentsRouter.post('/', validate(createAgentSchema), async (req, res) => {
  const db = await createDb();
  const { projectId, name, adapterType, config } = req.body;
  const [result] = await db.insert(agents).values({ projectId, name, adapterType, config: config ?? {} }).returning();
  res.status(201).json({ ok: true, data: result });
});

agentsRouter.patch('/:id', validate(updateAgentSchema), async (req, res) => {
  const db = await createDb();
  const updates: Record<string, unknown> = {};
  if (req.body.name) updates.name = req.body.name;
  if (req.body.config) updates.config = req.body.config;
  if (req.body.status) updates.status = req.body.status;

  const [result] = await db.update(agents).set(updates).where(eq(agents.id, req.params.id as string)).returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Agent not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

agentsRouter.post('/:id/heartbeat', async (req, res) => {
  const db = await createDb();
  const [result] = await db
    .update(agents)
    .set({ lastHeartbeat: new Date() })
    .where(eq(agents.id, req.params.id))
    .returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Agent not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

agentsRouter.delete('/:id', async (req, res) => {
  const db = await createDb();
  await db.delete(agents).where(eq(agents.id, req.params.id));
  res.json({ ok: true });
});
