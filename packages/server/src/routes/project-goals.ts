import { Router } from 'express';
import type { NextFunction, Request, Response } from 'express';
import { createDb, goals, projectAutomationRoutines, agents } from '@ddalkak/db';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';
import {
  evaluateProjectAutomation,
  getProjectAutomationRoutine,
  getProjectGoals,
  syncGoalHierarchyForProject,
} from '../services/goal-automation.service.js';

const createGoalSchema = z.object({
  title: z.string().min(1, 'title is required'),
  description: z.string().optional(),
  parentGoalId: z.string().uuid().optional().nullable(),
  status: z.enum(['planned', 'active', 'achieved', 'blocked']).optional(),
});

const updateGoalSchema = z.object({
  title: z.string().min(1).optional(),
  description: z.string().optional().nullable(),
  parentGoalId: z.string().uuid().optional().nullable(),
  status: z.enum(['planned', 'active', 'achieved', 'blocked']).optional(),
});

const upsertAutomationSchema = z.object({
  name: z.string().min(1).default('Project Goal Automation'),
  description: z.string().optional(),
  status: z.enum(['active', 'paused']).default('paused'),
  heartbeatMinutes: z.number().int().min(1).max(60).default(2),
  developerAgentId: z.string().uuid().optional().nullable(),
  reviewerAgentId: z.string().uuid().optional().nullable(),
  verifierAgentId: z.string().uuid().optional().nullable(),
});

export const projectGoalsRouter = Router();

type AsyncRouteHandler = (req: Request, res: Response, next: NextFunction) => Promise<void>;

function withRouteErrorHandling(handler: AsyncRouteHandler) {
  return async (req: Request, res: Response, next: NextFunction) => {
    try {
      await handler(req, res, next);
    } catch (error) {
      next(error);
    }
  };
}

async function validateParentGoalOwnership(
  projectId: string,
  parentGoalId: string | null | undefined,
  goalId?: string,
) {
  if (!parentGoalId) return null;
  if (goalId && goalId === parentGoalId) {
    return 'Goal cannot be its own parent';
  }

  const db = await createDb();
  const [parentGoal] = await db
    .select({
      id: goals.id,
      projectId: goals.projectId,
    })
    .from(goals)
    .where(eq(goals.id, parentGoalId));

  if (!parentGoal) {
    return 'Parent goal not found';
  }
  if (parentGoal.projectId !== projectId) {
    return 'Parent goal must belong to the same project';
  }
  if (goalId) {
    const projectGoals = await db
      .select({
        id: goals.id,
        parentGoalId: goals.parentGoalId,
      })
      .from(goals)
      .where(eq(goals.projectId, projectId));
    const parentByGoalId = new Map(projectGoals.map((goal) => [goal.id, goal.parentGoalId]));

    let cursor: string | null | undefined = parentGoalId;
    const visitedGoalIds = new Set<string>();
    while (cursor && !visitedGoalIds.has(cursor)) {
      if (cursor === goalId) {
        return 'Parent goal cannot be a descendant of the current goal';
      }
      visitedGoalIds.add(cursor);
      cursor = parentByGoalId.get(cursor) ?? null;
    }
  }
  return null;
}

projectGoalsRouter.get('/:id/goals', withRouteErrorHandling(async (req, res) => {
  const projectId = String(req.params.id);
  const result = await getProjectGoals(projectId);
  res.json({ ok: true, data: result });
}));

projectGoalsRouter.post('/:id/goals', validate(createGoalSchema), withRouteErrorHandling(async (req, res) => {
  const projectId = String(req.params.id);
  const parentGoalError = await validateParentGoalOwnership(projectId, req.body.parentGoalId ?? null);
  if (parentGoalError) {
    res.status(400).json({ ok: false, error: parentGoalError });
    return;
  }

  const db = await createDb();
  const [created] = await db.insert(goals).values({
    projectId,
    title: req.body.title,
    description: req.body.description,
    parentGoalId: req.body.parentGoalId ?? null,
    status: req.body.status ?? 'planned',
  }).returning();

  await syncGoalHierarchyForProject(projectId);
  res.status(201).json({ ok: true, data: created });
}));

projectGoalsRouter.patch('/:id/goals/:goalId', validate(updateGoalSchema), withRouteErrorHandling(async (req, res) => {
  const projectId = String(req.params.id);
  const goalId = String(req.params.goalId);
  if (req.body.parentGoalId !== undefined) {
    const parentGoalError = await validateParentGoalOwnership(projectId, req.body.parentGoalId, goalId);
    if (parentGoalError) {
      res.status(400).json({ ok: false, error: parentGoalError });
      return;
    }
  }

  const db = await createDb();
  const updates: Record<string, unknown> = { updatedAt: new Date() };
  if (req.body.title !== undefined) updates.title = req.body.title;
  if (req.body.description !== undefined) updates.description = req.body.description;
  if (req.body.parentGoalId !== undefined) updates.parentGoalId = req.body.parentGoalId;
  if (req.body.status !== undefined) updates.status = req.body.status;

  const [updated] = await db.update(goals)
    .set(updates)
    .where(and(eq(goals.id, goalId), eq(goals.projectId, projectId)))
    .returning();

  if (!updated) {
    res.status(404).json({ ok: false, error: 'Goal not found' });
    return;
  }

  await syncGoalHierarchyForProject(projectId);
  res.json({ ok: true, data: updated });
}));

projectGoalsRouter.get('/:id/automation', withRouteErrorHandling(async (req, res) => {
  const projectId = String(req.params.id);
  const routine = await getProjectAutomationRoutine(projectId);
  res.json({ ok: true, data: routine });
}));

projectGoalsRouter.put('/:id/automation', validate(upsertAutomationSchema), withRouteErrorHandling(async (req, res) => {
  const db = await createDb();
  const projectId = String(req.params.id);
  const agentIds = [
    req.body.developerAgentId,
    req.body.reviewerAgentId,
    req.body.verifierAgentId,
  ].filter((value): value is string => !!value);

  if (agentIds.length > 0) {
    const existingAgents = await db.select().from(agents).where(eq(agents.projectId, projectId));
    const existingAgentIds = new Set(existingAgents.map((agent) => agent.id));
    const invalidAgentId = agentIds.find((agentId) => !existingAgentIds.has(agentId));
    if (invalidAgentId) {
      res.status(400).json({ ok: false, error: 'Automation agents must belong to the same project' });
      return;
    }
  }

  const [existing] = await db.select().from(projectAutomationRoutines).where(eq(projectAutomationRoutines.projectId, projectId));
  const payload = {
    name: req.body.name,
    description: req.body.description,
    status: req.body.status,
    heartbeatMinutes: req.body.heartbeatMinutes,
    developerAgentId: req.body.developerAgentId ?? null,
    reviewerAgentId: req.body.reviewerAgentId ?? null,
    verifierAgentId: req.body.verifierAgentId ?? null,
    updatedAt: new Date(),
  };

  const [saved] = existing
    ? await db.update(projectAutomationRoutines)
        .set(payload)
        .where(eq(projectAutomationRoutines.id, existing.id))
        .returning()
    : await db.insert(projectAutomationRoutines)
        .values({
          projectId,
          ...payload,
        })
        .returning();

  res.json({ ok: true, data: saved });
}));

projectGoalsRouter.post('/:id/automation/run', withRouteErrorHandling(async (req, res) => {
  const projectId = String(req.params.id);
  const routine = await getProjectAutomationRoutine(projectId);
  if (!routine) {
    res.status(404).json({ ok: false, error: 'Automation routine not found' });
    return;
  }
  if (routine.status !== 'active') {
    res.status(409).json({ ok: false, error: 'Automation routine is paused' });
    return;
  }

  const result = await evaluateProjectAutomation(projectId);
  res.json({ ok: true, data: result });
}));
