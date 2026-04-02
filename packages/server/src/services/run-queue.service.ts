import { randomUUID } from 'crypto';

export type RunQueueState = 'queued' | 'leased' | 'running' | 'completed' | 'failed' | 'cancelled';

export interface RunQueueRequest {
  taskId: string;
  projectId: string;
  agentId: string;
  phaseId?: string;
  capabilityLabels?: string[];
  separationRequired?: boolean;
  timeoutSec: number;
  maxTurns: number;
}

export interface RunQueueItem extends RunQueueRequest {
  id: string;
  state: RunQueueState;
  workerId?: string;
  createdAt: Date;
  updatedAt: Date;
}

const runQueueItems = new Map<string, RunQueueItem>();

export function enqueueRun(request: RunQueueRequest): RunQueueItem {
  const now = new Date();
  const item: RunQueueItem = {
    ...request,
    id: randomUUID(),
    state: 'queued',
    createdAt: now,
    updatedAt: now,
  };
  runQueueItems.set(item.id, item);
  return item;
}

export function leaseRun(queueId: string, workerId: string): RunQueueItem | null {
  const item = runQueueItems.get(queueId);
  if (!item) return null;
  const leased: RunQueueItem = {
    ...item,
    state: 'leased',
    workerId,
    updatedAt: new Date(),
  };
  runQueueItems.set(queueId, leased);
  return leased;
}

export function markRunRunning(queueId: string): RunQueueItem | null {
  const item = runQueueItems.get(queueId);
  if (!item) return null;
  const running: RunQueueItem = {
    ...item,
    state: 'running',
    updatedAt: new Date(),
  };
  runQueueItems.set(queueId, running);
  return running;
}

export function completeRun(queueId: string, state: Extract<RunQueueState, 'completed' | 'failed' | 'cancelled'>): RunQueueItem | null {
  const item = runQueueItems.get(queueId);
  if (!item) return null;
  const completed: RunQueueItem = {
    ...item,
    state,
    updatedAt: new Date(),
  };
  runQueueItems.set(queueId, completed);
  return completed;
}

export function getRunQueueItem(queueId: string): RunQueueItem | null {
  return runQueueItems.get(queueId) ?? null;
}
