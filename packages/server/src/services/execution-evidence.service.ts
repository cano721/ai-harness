import type { RunQueueItem } from './run-queue.service.js';
import type { WorkerRegistration } from './worker-registry.service.js';

export type WorkerHealthState = 'healthy' | 'stale' | 'offline' | 'pending' | 'unknown';
export type WorkerState = WorkerRegistration['status'] | 'unassigned';

export interface ExecutionEvidence {
  dispatchMode: 'local-inline' | 'remote-queued';
  queueId: string | null;
  queueState: string | null;
  queueAttempts: number;
  queuePhaseId: string | null;
  queueCapabilityLabels: string[];
  queueSeparationRequired: boolean;
  workerId: string | null;
  workerName: string | null;
  workerRuntimeKind: WorkerRegistration['runtimeKind'] | null;
  workerStatus: WorkerState;
  workerHealth: WorkerHealthState;
  workerActiveRunCount: number;
  workerConcurrency: number;
  workerAvailableCapacity: number;
  workerCapacityLabel: string;
  workerLastHeartbeat: string | null;
  waitReason: string | null;
}

export const WORKER_STALE_MS = 60_000;

export function getWorkerHealth(worker: WorkerRegistration | null | undefined, now = Date.now()): WorkerHealthState {
  if (!worker) return 'pending';
  if (worker.status === 'offline') return 'offline';
  const heartbeatAge = now - worker.lastHeartbeat.getTime();
  return heartbeatAge > WORKER_STALE_MS ? 'stale' : 'healthy';
}

export function buildExecutionEvidence(opts: {
  dispatchMode: 'local-inline' | 'remote-queued';
  queueItem?: RunQueueItem | null;
  worker?: WorkerRegistration | null;
  waitReason?: string | null;
  now?: number;
}): ExecutionEvidence {
  const { dispatchMode, queueItem, worker, waitReason, now } = opts;
  const workerStatus: WorkerState = worker?.status ?? 'unassigned';
  const workerHealth = getWorkerHealth(worker, now);
  const workerActiveRunCount = worker?.activeRunCount ?? 0;
  const workerConcurrency = worker?.concurrency ?? 0;
  const workerAvailableCapacity = worker ? Math.max(workerConcurrency - workerActiveRunCount, 0) : 0;

  return {
    dispatchMode,
    queueId: queueItem?.id ?? null,
    queueState: queueItem?.state ?? null,
    queueAttempts: queueItem?.attempts ?? 0,
    queuePhaseId: queueItem?.phaseId ?? null,
    queueCapabilityLabels: queueItem?.capabilityLabels ?? [],
    queueSeparationRequired: queueItem?.separationRequired === true,
    workerId: worker?.id ?? null,
    workerName: worker?.name ?? null,
    workerRuntimeKind: worker?.runtimeKind ?? null,
    workerStatus,
    workerHealth,
    workerActiveRunCount,
    workerConcurrency,
    workerAvailableCapacity,
    workerCapacityLabel: `${workerActiveRunCount}/${workerConcurrency}`,
    workerLastHeartbeat: worker?.lastHeartbeat?.toISOString() ?? null,
    waitReason: waitReason ?? null,
  };
}
