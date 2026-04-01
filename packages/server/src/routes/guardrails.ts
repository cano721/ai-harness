import { Router } from 'express';
import { createDb, guardrails, projects } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import { writeConfig, readConfig, ddalkakDirExists } from '@ddalkak/shared';

export const guardrailsRouter = Router();

// List guardrails for a project
guardrailsRouter.get('/:projectId', async (req, res) => {
  const db = await createDb();
  const result = await db.select().from(guardrails).where(eq(guardrails.projectId, req.params.projectId));
  res.json({ ok: true, data: result });
});

// Upsert guardrail
guardrailsRouter.post('/:projectId', async (req, res) => {
  const db = await createDb();
  const { key, value } = req.body;

  // Check if exists
  const existing = await db.select().from(guardrails)
    .where(eq(guardrails.projectId, req.params.projectId));
  const found = existing.find(g => g.key === key);

  let result;
  if (found) {
    [result] = await db.update(guardrails).set({ value }).where(eq(guardrails.id, found.id)).returning();
  } else {
    [result] = await db.insert(guardrails).values({
      projectId: req.params.projectId,
      key,
      value: String(value),
    }).returning();
  }

  await syncGuardrailsToFile(req.params.projectId);
  res.status(201).json({ ok: true, data: result });
});

// Delete guardrail
guardrailsRouter.delete('/:projectId/:id', async (req, res) => {
  const db = await createDb();
  await db.delete(guardrails).where(eq(guardrails.id, req.params.id));
  await syncGuardrailsToFile(req.params.projectId);
  res.json({ ok: true });
});

async function syncGuardrailsToFile(projectId: string) {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, projectId));
  if (!project?.path) return;

  const hasDdalkak = await ddalkakDirExists(project.path);
  if (!hasDdalkak) return;

  const allGuardrails = await db.select().from(guardrails).where(eq(guardrails.projectId, projectId));
  const guardrailMap: Record<string, string | number> = {};
  for (const g of allGuardrails) {
    guardrailMap[g.key] = isNaN(Number(g.value)) ? g.value : Number(g.value);
  }

  const existing = await readConfig(project.path);
  await writeConfig(project.path, {
    name: existing?.name ?? project.name,
    description: existing?.description ?? project.description ?? undefined,
    gitUrl: existing?.gitUrl ?? project.gitUrl ?? undefined,
    techStack: existing?.techStack,
    guardrails: guardrailMap,
  });
}
