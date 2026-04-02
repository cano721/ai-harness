import { Router } from 'express';
import { createDb, conventions, projects } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import { writeConventions, ddalkakDirExists } from '@ddalkak/shared';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';

const createConventionSchema = z.object({
  category: z.string().min(1, 'category is required'),
  rule: z.string().min(1, 'rule is required'),
  scope: z.string().optional(),
  enabled: z.boolean().optional(),
});

const updateConventionSchema = z.object({
  category: z.string().min(1).optional(),
  rule: z.string().min(1).optional(),
  scope: z.string().optional(),
  enabled: z.boolean().optional(),
});

export const conventionsRouter = Router();

// List conventions for a project
conventionsRouter.get('/:projectId', async (req, res) => {
  const db = await createDb();
  const result = await db.select().from(conventions).where(eq(conventions.projectId, req.params.projectId as string));
  res.json({ ok: true, data: result });
});

// Create convention
conventionsRouter.post('/:projectId', validate(createConventionSchema), async (req, res) => {
  const db = await createDb();
  const { category, rule, scope, enabled } = req.body;

  const [created] = await db.insert(conventions).values({
    projectId: req.params.projectId as string,
    category,
    rule,
    scope: scope ?? 'project',
    enabled: enabled ?? true,
  }).returning();

  // Sync to .ddalkak/ if project has path
  await syncConventionsToFile(req.params.projectId as string);

  res.status(201).json({ ok: true, data: created });
});

// Update convention
conventionsRouter.patch('/:projectId/:id', validate(updateConventionSchema), async (req, res) => {
  const db = await createDb();
  const updates: Record<string, unknown> = {};
  if (req.body.category !== undefined) updates.category = req.body.category;
  if (req.body.rule !== undefined) updates.rule = req.body.rule;
  if (req.body.scope !== undefined) updates.scope = req.body.scope;
  if (req.body.enabled !== undefined) updates.enabled = req.body.enabled;

  const [result] = await db.update(conventions).set(updates).where(eq(conventions.id, req.params.id as string)).returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Convention not found' });
    return;
  }

  await syncConventionsToFile(req.params.projectId as string);
  res.json({ ok: true, data: result });
});

// Delete convention
conventionsRouter.delete('/:projectId/:id', async (req, res) => {
  const db = await createDb();
  await db.delete(conventions).where(eq(conventions.id, req.params.id as string));
  await syncConventionsToFile(req.params.projectId as string);
  res.json({ ok: true });
});

// Sync DB conventions to .ddalkak/conventions.yaml
async function syncConventionsToFile(projectId: string) {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, projectId));
  if (!project?.path) return;

  const hasDdalkak = await ddalkakDirExists(project.path);
  if (!hasDdalkak) return;

  const allConventions = await db.select().from(conventions).where(eq(conventions.projectId, projectId));
  await writeConventions(project.path, allConventions.map(c => ({
    category: c.category,
    rule: c.rule,
    scope: c.scope,
    enabled: c.enabled,
  })));
}
