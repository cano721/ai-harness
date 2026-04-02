export interface WorkerRegistration {
  id: string;
  name: string;
  runtimeKind: 'local' | 'remote';
  adapterTypes: string[];
  capabilityLabels: string[];
  status: 'idle' | 'busy' | 'offline';
  concurrency: number;
  activeRunCount: number;
  lastHeartbeat: Date;
}

const workers = new Map<string, WorkerRegistration>();

function ensureLocalWorker() {
  const localWorker: WorkerRegistration = {
    id: 'local-inline-worker',
    name: 'Local Inline Worker',
    runtimeKind: 'local',
    adapterTypes: ['claude_local', 'codex_local', 'cursor_local'],
    capabilityLabels: ['implementation', 'review pass', 'validation', 'analysis', 'general purpose'],
    status: 'idle',
    concurrency: 1,
    activeRunCount: 0,
    lastHeartbeat: new Date(),
  };
  if (!workers.has(localWorker.id)) {
    workers.set(localWorker.id, localWorker);
  }
}

export function listWorkers(): WorkerRegistration[] {
  ensureLocalWorker();
  return [...workers.values()];
}

export function getWorker(workerId: string): WorkerRegistration | null {
  ensureLocalWorker();
  return workers.get(workerId) ?? null;
}

export function registerWorker(input: Omit<WorkerRegistration, 'activeRunCount' | 'lastHeartbeat'> & Partial<Pick<WorkerRegistration, 'activeRunCount' | 'lastHeartbeat'>>) {
  ensureLocalWorker();
  const worker: WorkerRegistration = {
    ...input,
    activeRunCount: input.activeRunCount ?? 0,
    lastHeartbeat: input.lastHeartbeat ?? new Date(),
  };
  workers.set(worker.id, worker);
  return worker;
}

export function getDefaultLocalWorker(): WorkerRegistration {
  ensureLocalWorker();
  return workers.get('local-inline-worker')!;
}

export function canWorkerAcceptRun(workerId: string): boolean {
  const worker = getWorker(workerId);
  if (!worker) return false;
  if (worker.status === 'offline') return false;
  return worker.activeRunCount < worker.concurrency;
}

export function heartbeatWorker(workerId: string) {
  const worker = workers.get(workerId);
  if (!worker) return null;
  const next: WorkerRegistration = {
    ...worker,
    lastHeartbeat: new Date(),
    status: worker.activeRunCount > 0 ? 'busy' : 'idle',
  };
  workers.set(workerId, next);
  return next;
}

export function markWorkerBusy(workerId: string) {
  const worker = workers.get(workerId);
  if (!worker) return;
  const nextActive = worker.activeRunCount + 1;
  workers.set(workerId, {
    ...worker,
    status: 'busy',
    activeRunCount: nextActive,
    lastHeartbeat: new Date(),
  });
}

export function markWorkerIdle(workerId: string) {
  const worker = workers.get(workerId);
  if (!worker) return;
  const nextActive = Math.max(0, worker.activeRunCount - 1);
  workers.set(workerId, {
    ...worker,
    status: nextActive > 0 ? 'busy' : 'idle',
    activeRunCount: nextActive,
    lastHeartbeat: new Date(),
  });
}
