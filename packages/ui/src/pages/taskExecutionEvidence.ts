type BadgeTone = 'blue' | 'green' | 'yellow' | 'red';

export interface ExecutionEvidenceBadge {
  label: string;
  tone: BadgeTone;
}

export interface ExecutionEvidenceView {
  dispatchMode: string;
  queueState: string;
  queueId: string | null;
  queueAttempts: number;
  queuePhaseId: string | null;
  queueCapabilityLabels: string[];
  queueSeparationRequired: boolean;
  workerName: string;
  workerStatus: string;
  workerHealth: string;
  workerCapacityLabel: string;
  workerRuntimeKind: string;
  workerLastHeartbeat: string | null;
  waitReason: string | null;
  reclaimRetrySummary: string;
  summaryLabel: string;
  badges: ExecutionEvidenceBadge[];
  lines: string[];
}

const STALE_HEARTBEAT_MS = 60_000;

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null;
}

function asNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  return null;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((entry): entry is string => typeof entry === 'string' && entry.trim().length > 0);
}

function formatHeartbeatLabel(workerLastHeartbeat: string | null, workerStatus: string, waitReason: string | null) {
  if (!workerLastHeartbeat) {
    if (workerStatus === 'unassigned') return waitReason ?? 'waiting for worker lease';
    return 'not yet reported by worker';
  }

  const parsed = Date.parse(workerLastHeartbeat);
  if (!Number.isFinite(parsed)) return workerLastHeartbeat;
  const ageSec = Math.max(0, Math.floor((Date.now() - parsed) / 1000));
  return `${workerLastHeartbeat} (${ageSec}s ago)`;
}

function toneForQueueState(state: string): BadgeTone {
  if (state === 'completed') return 'green';
  if (state === 'failed' || state === 'cancelled') return 'red';
  if (state === 'queued') return 'yellow';
  return 'blue';
}

function toneForWorkerStatus(status: string): BadgeTone {
  if (status === 'offline') return 'red';
  if (status === 'busy' || status === 'leased') return 'blue';
  if (status === 'idle') return 'green';
  return 'yellow';
}

function toneForWorkerHealth(health: string): BadgeTone {
  if (health === 'healthy') return 'green';
  if (health === 'pending') return 'yellow';
  if (health === 'stale' || health === 'offline') return 'red';
  return 'yellow';
}

export function parseExecutionEvidence(detail: Record<string, unknown>): ExecutionEvidenceView | null {
  const nestedExecution = asRecord(detail.execution);
  const hasInlineExecution = [
    'dispatchMode',
    'queueId',
    'queueState',
    'queueAttempts',
    'workerId',
    'workerName',
    'workerStatus',
    'workerHealth',
    'workerCapacityLabel',
    'waitReason',
  ].some((key) => key in detail);

  if (!nestedExecution && !hasInlineExecution) return null;

  const execution = nestedExecution ?? detail;
  const queueState = (asString(execution.queueState) ?? 'queued').toLowerCase();
  const dispatchMode = (asString(execution.dispatchMode) ?? 'local-inline').toLowerCase();
  const queueId = asString(execution.queueId);
  const queueAttempts = asNumber(execution.queueAttempts) ?? 0;
  const queuePhaseId = asString(execution.queuePhaseId);
  const queueCapabilityLabels = asStringArray(execution.queueCapabilityLabels);
  const queueSeparationRequired = execution.queueSeparationRequired === true;
  const workerStatus = (asString(execution.workerStatus) ?? (asString(execution.workerId) ? 'busy' : 'unassigned')).toLowerCase();
  const workerName = asString(execution.workerName) ?? asString(execution.workerId) ?? (workerStatus === 'unassigned' ? 'Pending worker lease' : 'Active worker');
  const workerRuntimeKind = asString(execution.workerRuntimeKind) ?? (dispatchMode === 'remote-queued' ? 'remote' : 'local');
  const workerCapacityLabel = asString(execution.workerCapacityLabel) ?? '0/0';
  const waitReason = asString(execution.waitReason);
  const workerLastHeartbeat = asString(execution.workerLastHeartbeat);
  let workerHealth = (asString(execution.workerHealth) ?? '').toLowerCase();

  if (workerStatus === 'offline') {
    workerHealth = 'offline';
  } else if (workerStatus === 'unassigned') {
    workerHealth = 'pending';
  } else if (workerLastHeartbeat) {
    const age = Date.now() - new Date(workerLastHeartbeat).getTime();
    if (Number.isFinite(age)) {
      workerHealth = age > STALE_HEARTBEAT_MS ? 'stale' : (workerHealth || 'healthy');
    } else if (!workerHealth) {
      workerHealth = 'healthy';
    }
  } else if (!workerHealth) {
    workerHealth = 'healthy';
  }

  if (workerHealth === 'unknown') {
    workerHealth = workerStatus === 'unassigned' ? 'pending' : 'healthy';
  }

  const reclaimContextParts: string[] = [];
  if (queueAttempts > 1) {
    reclaimContextParts.push(`retry attempt ${queueAttempts}`);
  } else if (queueAttempts === 1) {
    reclaimContextParts.push('first lease acquired');
  } else {
    reclaimContextParts.push('initial dispatch pending');
  }
  if (queuePhaseId) reclaimContextParts.push(`phase ${queuePhaseId}`);
  if (queueCapabilityLabels.length > 0) reclaimContextParts.push(`capabilities ${queueCapabilityLabels.join(', ')}`);
  if (queueSeparationRequired) reclaimContextParts.push('separation required');
  if (waitReason && !/waiting for worker lease/i.test(waitReason)) reclaimContextParts.push(waitReason);
  const reclaimRetrySummary = reclaimContextParts.join('; ');
  const heartbeatLabel = formatHeartbeatLabel(workerLastHeartbeat, workerStatus, waitReason);

  const summaryLabel = `${queueState} / ${workerStatus} / ${workerHealth} / ${workerCapacityLabel}`;
  const badges: ExecutionEvidenceBadge[] = [
    { label: `queue ${queueState}`, tone: toneForQueueState(queueState) },
    { label: `worker ${workerStatus}`, tone: toneForWorkerStatus(workerStatus) },
    { label: `health ${workerHealth}`, tone: toneForWorkerHealth(workerHealth) },
    { label: `capacity ${workerCapacityLabel}`, tone: 'blue' },
  ];
  const lines = [
    `Dispatch: ${dispatchMode}`,
    `Queue: ${queueState}${queueId ? ` (${queueId.slice(0, 8)})` : ''}, attempts ${queueAttempts}`,
    `Worker: ${workerName} (${workerRuntimeKind})`,
    `Worker health/state: ${workerHealth} / ${workerStatus}`,
    `Capacity: ${workerCapacityLabel}`,
    `Last heartbeat: ${heartbeatLabel}`,
    `Reclaim/retry context: ${reclaimRetrySummary}`,
    ...(waitReason ? [`Queue wait reason: ${waitReason}`] : []),
  ];

  return {
    dispatchMode,
    queueState,
    queueId,
    queueAttempts,
    queuePhaseId,
    queueCapabilityLabels,
    queueSeparationRequired,
    workerName,
    workerStatus,
    workerHealth,
    workerCapacityLabel,
    workerRuntimeKind,
    workerLastHeartbeat,
    waitReason,
    reclaimRetrySummary,
    summaryLabel,
    badges,
    lines,
  };
}
