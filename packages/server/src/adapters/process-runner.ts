import { spawn, type ChildProcess } from 'child_process';

const runningProcesses = new Map<string, ChildProcess>();

export interface RunProcessOptions {
  runId: string;
  command: string;
  args: string[];
  cwd: string;
  env: Record<string, string>;
  timeoutSec: number;
  onLog: (stream: 'stdout' | 'stderr', chunk: string) => void;
  onSpawn?: (pid: number) => void;
}

export interface RunProcessResult {
  exitCode: number | null;
  signal?: string;
  timedOut: boolean;
}

export async function runChildProcess(opts: RunProcessOptions): Promise<RunProcessResult> {
  return new Promise((resolve) => {
    const mergedEnv = { ...process.env, ...opts.env };

    // Remove Claude Code nesting guard vars
    delete mergedEnv.CLAUDECODE;
    delete mergedEnv.CLAUDE_CODE_ENTRYPOINT;
    delete mergedEnv.CLAUDE_CODE_SESSION;
    delete mergedEnv.CLAUDE_CODE_PARENT_SESSION;

    const child = spawn(opts.command, opts.args, {
      cwd: opts.cwd,
      env: mergedEnv,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    runningProcesses.set(opts.runId, child);

    if (child.pid && opts.onSpawn) {
      opts.onSpawn(child.pid);
    }

    child.stdout?.on('data', (chunk: Buffer) => {
      opts.onLog('stdout', chunk.toString());
    });

    child.stderr?.on('data', (chunk: Buffer) => {
      opts.onLog('stderr', chunk.toString());
    });

    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => {
        if (!child.killed) child.kill('SIGKILL');
      }, 5000);
    }, opts.timeoutSec * 1000);

    child.on('close', (code, signal) => {
      clearTimeout(timer);
      runningProcesses.delete(opts.runId);
      resolve({
        exitCode: code,
        signal: signal ?? undefined,
        timedOut,
      });
    });

    child.on('error', (err) => {
      clearTimeout(timer);
      runningProcesses.delete(opts.runId);
      opts.onLog('stderr', `Process error: ${err.message}`);
      resolve({ exitCode: 1, timedOut: false });
    });
  });
}

export function killProcess(runId: string): boolean {
  const proc = runningProcesses.get(runId);
  if (proc) {
    proc.kill('SIGTERM');
    return true;
  }
  return false;
}
