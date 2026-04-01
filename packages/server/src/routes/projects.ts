import { Router } from 'express';
import { createDb, projects, schema } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import type { ApiResponse, Project } from '@ddalkak/shared';

export const projectsRouter = Router();

// List all projects
projectsRouter.get('/', async (_req, res) => {
  const db = await createDb();
  const result = await db.select().from(projects);
  const response: ApiResponse<typeof result> = { ok: true, data: result };
  res.json(response);
});

// Get single project
projectsRouter.get('/:id', async (req, res) => {
  const db = await createDb();
  const [result] = await db.select().from(projects).where(eq(projects.id, req.params.id));
  if (!result) {
    res.status(404).json({ ok: false, error: 'Project not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

// Create project
projectsRouter.post('/', async (req, res) => {
  const db = await createDb();
  const { name, path, gitUrl, description } = req.body;
  const [result] = await db.insert(projects).values({ name, path, gitUrl, description }).returning();
  res.status(201).json({ ok: true, data: result });
});

// Update project
projectsRouter.patch('/:id', async (req, res) => {
  const db = await createDb();
  const { name, path, gitUrl, description } = req.body;
  const [result] = await db
    .update(projects)
    .set({ name, path, gitUrl, description, updatedAt: new Date() })
    .where(eq(projects.id, req.params.id))
    .returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Project not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

// Delete project
projectsRouter.delete('/:id', async (req, res) => {
  const db = await createDb();
  await db.delete(projects).where(eq(projects.id, req.params.id));
  res.json({ ok: true });
});
