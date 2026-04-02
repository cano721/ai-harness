import { Router } from 'express';
import { createDb, activityLog, agents, projects } from '@ddalkak/db';
import { eq, desc, sql } from 'drizzle-orm';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';

export const activityRouter = Router();

// List activity (most recent first, with pagination)
activityRouter.get('/', async (req, res) => {
  const db = await createDb();
  const limit = parseInt(req.query.limit as string) || 50;
  const offset = parseInt(req.query.offset as string) || 0;
  const eventType = req.query.eventType as string | undefined;
  const projectId = req.query.projectId as string | undefined;

  let query = db.select().from(activityLog).orderBy(desc(activityLog.createdAt)).limit(limit).offset(offset);

  // Filters applied via raw SQL since drizzle chaining is limited
  const conditions: any[] = [];
  if (eventType) conditions.push(eq(activityLog.eventType, eventType));
  if (projectId) conditions.push(eq(activityLog.projectId, projectId));

  let result;
  if (conditions.length === 1) {
    result = await db.select().from(activityLog).where(conditions[0]).orderBy(desc(activityLog.createdAt)).limit(limit).offset(offset);
  } else if (conditions.length === 2) {
    result = await db.select().from(activityLog).where(sql`${conditions[0]} AND ${conditions[1]}`).orderBy(desc(activityLog.createdAt)).limit(limit).offset(offset);
  } else {
    result = await db.select().from(activityLog).orderBy(desc(activityLog.createdAt)).limit(limit).offset(offset);
  }

  // Enrich with names
  const allAgents = await db.select().from(agents);
  const allProjects = await db.select().from(projects);
  const agentMap = Object.fromEntries(allAgents.map(a => [a.id, a]));
  const projectMap = Object.fromEntries(allProjects.map(p => [p.id, p]));

  const enriched = result.map(r => ({
    ...r,
    agentName: r.agentId ? agentMap[r.agentId]?.name : undefined,
    projectName: r.projectId ? projectMap[r.projectId]?.name : undefined,
  }));

  res.json({ ok: true, data: enriched });
});

const securityEventSchema = z.object({
  projectId: z.string().uuid('projectId must be a valid UUID'),
  agentId: z.string().uuid('agentId must be a valid UUID').optional(),
  eventType: z.string().min(1, 'eventType is required'),
  detail: z.record(z.string(), z.unknown()).optional().default({}),
});

// Log a security event
activityRouter.post('/security', validate(securityEventSchema), async (req, res) => {
  const db = await createDb();
  const { projectId, agentId, eventType, detail } = req.body;

  const normalizedEventType = eventType.startsWith('security.') ? eventType : `security.${eventType}`;

  const [created] = await db.insert(activityLog).values({
    projectId,
    agentId: agentId ?? null,
    eventType: normalizedEventType,
    detail,
  }).returning();

  res.status(201).json({ ok: true, data: created });
});

// Security events (blocked actions)
activityRouter.get('/security', async (req, res) => {
  const db = await createDb();
  const limit = parseInt(req.query.limit as string) || 50;

  const result = await db.select().from(activityLog)
    .where(sql`${activityLog.eventType} LIKE 'security.%'`)
    .orderBy(desc(activityLog.createdAt))
    .limit(limit);

  res.json({ ok: true, data: result });
});

// Event counts (for dashboard)
activityRouter.get('/counts', async (_req, res) => {
  const db = await createDb();
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();

  const [securityCount] = await db.select({
    count: sql<number>`COUNT(*)`,
  }).from(activityLog)
    .where(sql`${activityLog.eventType} LIKE 'security.%' AND ${activityLog.createdAt} >= ${todayStart}`);

  const [taskCount] = await db.select({
    count: sql<number>`COUNT(*)`,
  }).from(activityLog)
    .where(sql`${activityLog.eventType} LIKE 'task.%' AND ${activityLog.createdAt} >= ${todayStart}`);

  res.json({
    ok: true,
    data: {
      securityEventsToday: Number(securityCount?.count ?? 0),
      taskEventsToday: Number(taskCount?.count ?? 0),
    },
  });
});
