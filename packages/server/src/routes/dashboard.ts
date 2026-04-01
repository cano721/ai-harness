import { Router } from 'express';
import { createDb, agents, conventions, costDaily, activityLog } from '@ddalkak/db';
import { eq, sql } from 'drizzle-orm';
import type { DashboardSummary, ApiResponse } from '@ddalkak/shared';

export const dashboardRouter = Router();

dashboardRouter.get('/', async (_req, res) => {
  const db = await createDb();

  // Agent counts
  const allAgents = await db.select().from(agents);
  const activeAgents = allAgents.length;
  const runningAgents = allAgents.filter(a => a.status === 'running').length;

  // Convention compliance (enabled / total)
  const allConventions = await db.select().from(conventions);
  const enabledCount = allConventions.filter(c => c.enabled).length;
  const conventionCompliance = allConventions.length > 0
    ? Math.round((enabledCount / allConventions.length) * 100)
    : 0;

  // Monthly cost
  const now = new Date();
  const monthStart = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-01`;
  const [costRow] = await db.select({
    total: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
  }).from(costDaily).where(sql`${costDaily.date} >= ${monthStart}`);

  // Security events today
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();
  const [secRow] = await db.select({
    count: sql<number>`COUNT(*)`,
  }).from(activityLog)
    .where(sql`${activityLog.eventType} LIKE 'security.%' AND ${activityLog.createdAt} >= ${todayStart}`);

  const summary: DashboardSummary = {
    activeAgents,
    runningAgents,
    conventionCompliance,
    securityEvents: Number(secRow?.count ?? 0),
    monthlyCostUsd: Number(costRow?.total ?? 0),
    monthlyBudgetUsd: 300,
  };

  const response: ApiResponse<DashboardSummary> = { ok: true, data: summary };
  res.json(response);
});
