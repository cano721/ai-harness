import { randomUUID } from 'crypto';

export type RunQueueState = 'queued' | 'leased' | 'running' | 'completed' | 'failed' | 'cancelled';

export interface RunQueueRequest {
  taskId: string;
  projectId: string;
  agentId: string;
  adapterType?: string;
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
  attempts: number;
  leaseExpiresAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const runQueueItems = new Map<string, RunQueueItem>();

interface QueueLeaseMatchOptions {
  adapterTypes?: string[];
  capabilityLabels?: string[];
}

function includesAll(labels: string[], required: string[]) {
  return required.every((label) => labels.includes(label));
}

function matchesLeaseOptions(item: RunQueueItem, options: QueueLeaseMatchOptions) {
  if (options.adapterTypes && options.adapterTypes.length > 0) {
    if (!item.adapterType || !options.adapterTypes.includes(item.adapterType)) {
      return false;
    }
  }
  if (options.capabilityLabels && options.capabilityLabels.length > 0) {
    if (!includesAll(options.capabilityLabels, item.capabilityLabels ?? [])) {
      return false;
    }
  }
  return true;
}

export function enqueueRun(request: RunQueueRequest): RunQueueItem {
  const now = new Date();
  const item: RunQueueItem = {
    ...request,
    id: randomUUID(),
    state: 'queued',
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  };
  runQueueItems.set(item.id, item);
  return item;
}

export function leaseRun(queueId: string, workerId: string): RunQueueItem | null {
  const item = runQueueItems.get(queueId);
  if (!item || item.state !== 'queued') return null;
  const leased: RunQueueItem = {
    ...item,
    state: 'leased',
    workerId,
    attempts: item.attempts + 1,
    updatedAt: new Date(),
  };
  runQueueItems.set(queueId, leased);
  return leased;
}

export function leaseNextQueuedRun(workerId: string, options: QueueLeaseMatchOptions = {}): RunQueueItem | null {
  const candidate = [...runQueueItems.values()]
    .filter((item) => item.state === 'queued' && matchesLeaseOptions(item, options))
    .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime())[0];

  if (!candidate) return null;
  return leaseRun(candidate.id, workerId);
}

export function markRunRunning(queueId: string): RunQueueItem | null {
  const item = runQueueItems.get(queueId);
  if (!item || item.state !== 'leased') return null;
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
  if (!item || (item.state !== 'leased' && item.state !== 'running')) return null;
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

export function listRunQueueItems(): RunQueueItem[] {
  return [...runQueueItems.values()].sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
}
