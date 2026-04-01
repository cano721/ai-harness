import { Router } from 'express';
import { createDb, agents } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import type { ApiResponse } from '@ddalkak/shared';

export const agentsRouter = Router();

agentsRouter.get('/', async (_req, res) => {
  const db = await createDb();
  const result = await db.select().from(agents);
  res.json({ ok: true, data: result } satisfies ApiResponse);
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

agentsRouter.post('/', async (req, res) => {
  const db = await createDb();
  const { projectId, name, adapterType, config } = req.body;
  const [result] = await db.insert(agents).values({ projectId, name, adapterType, config: config ?? {} }).returning();
  res.status(201).json({ ok: true, data: result });
});

agentsRouter.patch('/:id', async (req, res) => {
  const db = await createDb();
  const updates: Record<string, unknown> = {};
  if (req.body.name) updates.name = req.body.name;
  if (req.body.config) updates.config = req.body.config;
  if (req.body.status) updates.status = req.body.status;

  const [result] = await db.update(agents).set(updates).where(eq(agents.id, req.params.id)).returning();
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
