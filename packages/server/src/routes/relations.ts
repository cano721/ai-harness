import { Router } from 'express';
import { createDb, projectRelations, projects } from '@ddalkak/db';
import { eq, or } from 'drizzle-orm';

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
relationsRouter.post('/', async (req, res) => {
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
