import { createDb, taskRuns, costDaily, agents, tasks, projects } from '@ddalkak/db';
import { eq, sql, isNotNull } from 'drizzle-orm';

export interface AgentMetric {
  agentId: string;
  agentName: string;
  adapterType: string;
  totalRuns: number;
  successRuns: number;
  successRate: number;
  avgDurationSec: number;
  totalCostUsd: number;
  costPerTask: number;
}

export interface ProjectMetric {
  projectId: string;
  projectName: string;
  totalTasks: number;
  doneTasks: number;
  inProgressTasks: number;
  completionRate: number;
  totalCostUsd: number;
}

export interface SystemMetric {
  totalAgents: number;
  runningAgents: number;
  idleAgents: number;
  utilizationRate: number;
  totalTaskRuns: number;
  totalCostUsd: number;
  avgSuccessRate: number;
}

export async function getAgentMetrics(): Promise<AgentMetric[]> {
  const db = await createDb();

  const runs = await db.select({
    agentId: taskRuns.agentId,
    totalRuns: sql<number>`COUNT(*)`,
    successRuns: sql<number>`COUNT(CASE WHEN ${taskRuns.exitCode} = 0 THEN 1 END)`,
    avgDurationSec: sql<number>`COALESCE(AVG(
      CASE WHEN ${taskRuns.endedAt} IS NOT NULL
        THEN EXTRACT(EPOCH FROM (${taskRuns.endedAt} - ${taskRuns.startedAt}))
      END
    ), 0)`,
  }).from(taskRuns).groupBy(taskRuns.agentId);

  const costs = await db.select({
    agentId: costDaily.agentId,
    totalCostUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
  }).from(costDaily).groupBy(costDaily.agentId);
  const costMap = Object.fromEntries(costs.map(c => [c.agentId, c.totalCostUsd]));

  const allAgents = await db.select().from(agents);
  const agentMap = Object.fromEntries(allAgents.map(a => [a.id, a]));

  return runs.map(r => {
    const totalRuns = Number(r.totalRuns);
    const successRuns = Number(r.successRuns);
    const totalCostUsd = costMap[r.agentId] ?? 0;
    return {
      agentId: r.agentId,
      agentName: agentMap[r.agentId]?.name ?? 'unknown',
      adapterType: agentMap[r.agentId]?.adapterType ?? 'unknown',
      totalRuns,
      successRuns,
      successRate: totalRuns > 0 ? successRuns / totalRuns : 0,
      avgDurationSec: Math.round(Number(r.avgDurationSec)),
      totalCostUsd,
      costPerTask: totalRuns > 0 ? totalCostUsd / totalRuns : 0,
    };
  });
}

export async function getProjectMetrics(): Promise<ProjectMetric[]> {
  const db = await createDb();

  const taskCounts = await db.select({
    projectId: tasks.projectId,
    totalTasks: sql<number>`COUNT(*)`,
    doneTasks: sql<number>`COUNT(CASE WHEN ${tasks.status} = 'done' THEN 1 END)`,
    inProgressTasks: sql<number>`COUNT(CASE WHEN ${tasks.status} = 'in_progress' THEN 1 END)`,
  }).from(tasks).groupBy(tasks.projectId);

  const costs = await db.select({
    projectId: costDaily.projectId,
    totalCostUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
  }).from(costDaily).groupBy(costDaily.projectId);
  const costMap = Object.fromEntries(costs.map(c => [c.projectId, c.totalCostUsd]));

  const allProjects = await db.select().from(projects);
  const projectMap = Object.fromEntries(allProjects.map(p => [p.id, p]));

  return taskCounts.map(r => {
    const totalTasks = Number(r.totalTasks);
    const doneTasks = Number(r.doneTasks);
    return {
      projectId: r.projectId,
      projectName: projectMap[r.projectId]?.name ?? 'unknown',
      totalTasks,
      doneTasks,
      inProgressTasks: Number(r.inProgressTasks),
      completionRate: totalTasks > 0 ? doneTasks / totalTasks : 0,
      totalCostUsd: costMap[r.projectId] ?? 0,
    };
  });
}

export async function getSystemMetrics(): Promise<SystemMetric> {
  const db = await createDb();

  const [agentCounts] = await db.select({
    totalAgents: sql<number>`COUNT(*)`,
    runningAgents: sql<number>`COUNT(CASE WHEN ${agents.status} = 'running' THEN 1 END)`,
    idleAgents: sql<number>`COUNT(CASE WHEN ${agents.status} = 'idle' THEN 1 END)`,
  }).from(agents);

  const [runStats] = await db.select({
    totalRuns: sql<number>`COUNT(*)`,
    successRuns: sql<number>`COUNT(CASE WHEN ${taskRuns.exitCode} = 0 THEN 1 END)`,
  }).from(taskRuns);

  const [costStats] = await db.select({
    totalCostUsd: sql<number>`COALESCE(SUM(${costDaily.totalUsd}), 0)`,
  }).from(costDaily);

  const totalAgents = Number(agentCounts?.totalAgents ?? 0);
  const runningAgents = Number(agentCounts?.runningAgents ?? 0);
  const totalRuns = Number(runStats?.totalRuns ?? 0);
  const successRuns = Number(runStats?.successRuns ?? 0);

  return {
    totalAgents,
    runningAgents,
    idleAgents: Number(agentCounts?.idleAgents ?? 0),
    utilizationRate: totalAgents > 0 ? runningAgents / totalAgents : 0,
    totalTaskRuns: totalRuns,
    totalCostUsd: Number(costStats?.totalCostUsd ?? 0),
    avgSuccessRate: totalRuns > 0 ? successRuns / totalRuns : 0,
  };
}
