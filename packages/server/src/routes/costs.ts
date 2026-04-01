import { Router } from 'express';
import { createDb, costDaily, taskRuns, agents, projects } from '@ddalkak/db';
import { eq, sql, and } from 'drizzle-orm';

export const costsRouter = Router();

// Get cost summary (monthly totals)
costsRouter.get('/summary', async (_req, res) => {
  const db = await createDb();
  const now = new Date();
  const monthStart = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-01`;

  const rows = await db.select({
    totalUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
    tokensIn: sql<number>`COALESCE(SUM(${costDaily.tokensIn}), 0)`,
    tokensOut: sql<number>`COALESCE(SUM(${costDaily.tokensOut}), 0)`,
  }).from(costDaily).where(sql`${costDaily.date} >= ${monthStart}`);

  res.json({ ok: true, data: rows[0] ?? { totalUsd: 0, tokensIn: 0, tokensOut: 0 } });
});

// Get costs by agent
costsRouter.get('/by-agent', async (_req, res) => {
  const db = await createDb();
  const rows = await db.select({
    agentId: costDaily.agentId,
    totalUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
    tokensIn: sql<number>`COALESCE(SUM(${costDaily.tokensIn}), 0)`,
    tokensOut: sql<number>`COALESCE(SUM(${costDaily.tokensOut}), 0)`,
  }).from(costDaily).groupBy(costDaily.agentId);

  // Enrich with agent names
  const allAgents = await db.select().from(agents);
  const agentMap = Object.fromEntries(allAgents.map(a => [a.id, a]));

  const enriched = rows.map(r => ({
    ...r,
    agentName: agentMap[r.agentId]?.name ?? 'unknown',
    adapterType: agentMap[r.agentId]?.adapterType ?? 'unknown',
  }));

  res.json({ ok: true, data: enriched });
});

// Get costs by project
costsRouter.get('/by-project', async (_req, res) => {
  const db = await createDb();
  const rows = await db.select({
    projectId: costDaily.projectId,
    totalUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
    tokensIn: sql<number>`COALESCE(SUM(${costDaily.tokensIn}), 0)`,
    tokensOut: sql<number>`COALESCE(SUM(${costDaily.tokensOut}), 0)`,
  }).from(costDaily).groupBy(costDaily.projectId);

  const allProjects = await db.select().from(projects);
  const projectMap = Object.fromEntries(allProjects.map(p => [p.id, p]));

  const enriched = rows.map(r => ({
    ...r,
    projectName: projectMap[r.projectId]?.name ?? 'unknown',
  }));

  res.json({ ok: true, data: enriched });
});

// Get daily costs (for chart)
costsRouter.get('/daily', async (req, res) => {
  const db = await createDb();
  const days = parseInt(req.query.days as string) || 14;
  const now = new Date();
  const startDate = new Date(now.getTime() - days * 86400000);
  const startStr = startDate.toISOString().slice(0, 10);

  const rows = await db.select({
    date: costDaily.date,
    totalUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
    tokensIn: sql<number>`COALESCE(SUM(${costDaily.tokensIn}), 0)`,
    tokensOut: sql<number>`COALESCE(SUM(${costDaily.tokensOut}), 0)`,
  }).from(costDaily).where(sql`${costDaily.date} >= ${startStr}`).groupBy(costDaily.date);

  res.json({ ok: true, data: rows });
});
