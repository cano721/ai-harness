import { Router } from 'express';
import { createDb, projects } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import { loadSkills, getSkill } from '../services/skill-loader.service.js';

export const skillsRouter = Router();

// GET /api/skills?projectId=X — list skills for a project
skillsRouter.get('/', async (req, res) => {
  const { projectId } = req.query as { projectId?: string };
  if (!projectId) {
    res.status(400).json({ ok: false, error: 'projectId is required' });
    return;
  }

  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, projectId));
  if (!project) {
    res.status(404).json({ ok: false, error: 'Project not found' });
    return;
  }

  const skills = await loadSkills(project.path ?? '');
  res.json({
    ok: true,
    data: skills.map(s => ({ name: s.name, path: s.path, updatedAt: s.updatedAt })),
  });
});

// GET /api/skills/:name?projectId=X — get specific skill content
skillsRouter.get('/:name', async (req, res) => {
  const { projectId } = req.query as { projectId?: string };
  if (!projectId) {
    res.status(400).json({ ok: false, error: 'projectId is required' });
    return;
  }

  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, projectId));
  if (!project) {
    res.status(404).json({ ok: false, error: 'Project not found' });
    return;
  }

  const skill = await getSkill(project.path ?? '', req.params.name);
  if (!skill) {
    res.status(404).json({ ok: false, error: `Skill not found: ${req.params.name}` });
    return;
  }

  res.json({ ok: true, data: skill });
});
