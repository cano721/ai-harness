import { Router } from 'express';
import { createDb, projectRelations, projects } from '@ddalkak/db';
import { eq, or } from 'drizzle-orm';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';

const createRelationSchema = z.object({
  sourceProjectId: z.string().min(1, 'sourceProjectId is required'),
  targetProjectId: z.string().min(1, 'targetProjectId is required'),
  type: z.string().optional(),
});

export const relationsRouter = Router();

// Get relations for a project
relationsRouter.get('/:projectId', async (req, res) => {
  const db = await createDb();
  const result = await db.select().from(projectRelations)
    .where(
      or(
        eq(projectRelations.sourceProjectId, req.params.projectId),
        eq(projectRelations.targetProjectId, req.params.projectId),
      )
    );

  // Enrich with project names
  const allProjects = await db.select().from(projects);
  const projectMap = Object.fromEntries(allProjects.map(p => [p.id, p]));

  const enriched = result.map(r => ({
    ...r,
    sourceProject: projectMap[r.sourceProjectId],
    targetProject: projectMap[r.targetProjectId],
  }));

  res.json({ ok: true, data: enriched });
});

// Create relation
relationsRouter.post('/', validate(createRelationSchema), async (req, res) => {
  const db = await createDb();
  const { sourceProjectId, targetProjectId, type } = req.body;

  const [created] = await db.insert(projectRelations).values({
    sourceProjectId,
    targetProjectId,
    type: type ?? 'depends_on',
  }).returning();

  res.status(201).json({ ok: true, data: created });
});

// Delete relation
relationsRouter.delete('/:id', async (req, res) => {
  const db = await createDb();
  await db.delete(projectRelations).where(eq(projectRelations.id, req.params.id));
  res.json({ ok: true });
});
