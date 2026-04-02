import { createDb, agents, tasks } from '@ddalkak/db';
import { and, eq } from 'drizzle-orm';
import { runTask } from './task-runner.service.js';
import { completeRun, enqueueRun, leaseRun, markRunRunning } from './run-queue.service.js';
import { getDefaultLocalWorker, markWorkerBusy, markWorkerIdle } from './worker-registry.service.js';

interface DispatchWorkflowMetadata {
  lastCompletedAgentId?: string;
  lastBlockedReason?: string;
  phases?: Array<{ id?: string; status?: string; enforceSeparation?: boolean }>;
}

interface DispatchTask {
  id: string;
  projectId: string;
  agentId: string | null;
  metadata: unknown;
}

interface DispatchTaskRunOptions {
  task: DispatchTask;
  requestedAgentId?: string | null;
  dispatchMode?: 'local-inline' | 'remote-queued';
  timeoutSec?: number;
  maxTurns?: number;
}

interface DispatchBlockedResult {
  ok: false;
  status: 409 | 400;
  error: string;
}

interface DispatchAcceptedResult {
  ok: true;
  agentId: string;
  status: 'started' | 'queued';
  dispatchMode: 'local-inline' | 'remote-queued';
  queueState: 'running' | 'queued';
  queueId: string;
  workerId: string | null;
}

export type DispatchTaskRunResult = DispatchBlockedResult | DispatchAcceptedResult;

async function pickReviewAgent(task: { projectId: string }, lastCompletedAgentId?: string) {
  const db = await createDb();
  const projectAgents = await db
    .select()
    .from(agents)
    .where(and(eq(agents.projectId, task.projectId), eq(agents.status, 'idle')));

  const candidates = lastCompletedAgentId
    ? projectAgents.filter((agent) => agent.id !== lastCompletedAgentId)
    : projectAgents;
  const reviewer = candidates.find((agent) => /review/i.test(agent.name));
  return reviewer ?? candidates[0] ?? null;
}

export async function dispatchTaskRun(opts: DispatchTaskRunOptions): Promise<DispatchTaskRunResult> {
  const db = await createDb();
  const workflow = (opts.task.metadata as { workflow?: DispatchWorkflowMetadata } | null | undefined)?.workflow;
  const activePhase = workflow?.phases?.find((phase) => phase.status === 'in_progress');
  const dispatchMode = opts.dispatchMode ?? 'local-inline';
  const timeoutSec = opts.timeoutSec ?? 300;
  const maxTurns = opts.maxTurns ?? 20;
  let agentId = opts.requestedAgentId ?? opts.task.agentId ?? undefined;

  if (activePhase?.enforceSeparation) {
    if (opts.requestedAgentId && workflow?.lastCompletedAgentId === opts.requestedAgentId) {
      return {
        ok: false,
        status: 409,
        error: 'Separation policy requires a different agent for the active review phase',
      };
    }

    if (!agentId || workflow?.lastCompletedAgentId === agentId) {
      const reviewAgent = await pickReviewAgent(opts.task, workflow?.lastCompletedAgentId);
      if (!reviewAgent) {
        const blockedWorkflow = workflow
          ? {
              ...workflow,
              lastBlockedReason: 'No idle reviewer agent available for the active review phase.',
              phases: (workflow.phases ?? []).map((phase) => (
                phase.status === 'in_progress' ? { ...phase, status: 'blocked' } : phase
              )),
            }
          : workflow;

        await db.update(tasks).set({
          status: 'blocked',
          metadata: blockedWorkflow ? { ...(opts.task.metadata as Record<string, unknown>), workflow: blockedWorkflow } : opts.task.metadata,
          updatedAt: new Date(),
        }).where(eq(tasks.id, opts.task.id));

        return {
          ok: false,
          status: 409,
          error: 'Separation policy requires an idle reviewer agent for the active review phase',
        };
      }
      agentId = reviewAgent.id;
    }
  }

  if (!agentId) {
    return {
      ok: false,
      status: 400,
      error: 'No agent assigned',
    };
  }

  const [agent] = await db.select().from(agents).where(eq(agents.id, agentId));
  if (!agent) {
    return {
      ok: false,
      status: 400,
      error: 'Assigned agent not found',
    };
  }

  const capabilityLabels = activePhase?.enforceSeparation
    ? ['review pass']
    : ['implementation'];

  const queueItem = enqueueRun({
    taskId: opts.task.id,
    projectId: opts.task.projectId,
    agentId,
    adapterType: agent.adapterType,
    phaseId: activePhase?.id,
    capabilityLabels,
    separationRequired: activePhase?.enforceSeparation === true,
    timeoutSec,
    maxTurns,
  });

  if (dispatchMode === 'remote-queued') {
    return {
      ok: true,
      agentId,
      status: 'queued',
      dispatchMode,
      queueState: 'queued',
      queueId: queueItem.id,
      workerId: null,
    };
  }

  const worker = getDefaultLocalWorker();
  leaseRun(queueItem.id, worker.id);
  markRunRunning(queueItem.id);
  markWorkerBusy(worker.id);

  runTask({ taskId: opts.task.id, agentId, timeoutSec, maxTurns })
    .then((result) => {
      completeRun(queueItem.id, result.exitCode === 0 ? 'completed' : 'failed');
    })
    .catch(() => {
      completeRun(queueItem.id, 'failed');
    })
    .finally(() => {
      markWorkerIdle(worker.id);
    });

  return {
    ok: true,
    agentId,
    status: 'started',
    dispatchMode,
    queueState: 'running',
    queueId: queueItem.id,
    workerId: worker.id,
  };
}
