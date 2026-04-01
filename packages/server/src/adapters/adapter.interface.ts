export interface AdapterDetectResult {
  installed: boolean;
  version?: string;
  command?: string;
}

export interface AdapterExecuteOptions {
  runId: string;
  prompt: string;
  cwd: string;
  env: Record<string, string>;
  timeoutSec: number;
  maxTurns?: number;
  onLog: (stream: 'stdout' | 'stderr', chunk: string) => void;
  onSpawn?: (pid: number) => void;
}

export interface AdapterExecuteResult {
  exitCode: number | null;
  signal?: string;
  timedOut: boolean;
  usage?: {
    inputTokens: number;
    outputTokens: number;
    cachedTokens?: number;
  };
  model?: string;
  costUsd?: number;
}

export interface AgentAdapter {
  type: string;
  detect(): Promise<AdapterDetectResult>;
  execute(opts: AdapterExecuteOptions): Promise<AdapterExecuteResult>;
  kill(runId: string): void;
}
