import { execSync } from 'child_process';
import type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from '@ddalkak/adapter-utils';
import { runChildProcess, killProcess } from '@ddalkak/adapter-utils';

export class CursorLocalAdapter implements AgentAdapter {
  type = 'cursor_local';

  async detect(): Promise<AdapterDetectResult> {
    try {
      const version = execSync('cursor --version', { encoding: 'utf-8', timeout: 5000 }).trim();
      return { installed: true, version, command: 'cursor' };
    } catch {
      return { installed: false };
    }
  }

  async execute(opts: AdapterExecuteOptions): Promise<AdapterExecuteResult> {
    const result = await runChildProcess({
      runId: opts.runId,
      command: 'cursor',
      args: ['--headless', '--max-turns', String(opts.maxTurns ?? 20), opts.prompt],
      cwd: opts.cwd,
      env: opts.env,
      timeoutSec: opts.timeoutSec,
      onLog: opts.onLog,
      onSpawn: opts.onSpawn,
    });

    return {
      exitCode: result.exitCode,
      signal: result.signal,
      timedOut: result.timedOut,
    };
  }

  kill(runId: string): void {
    killProcess(runId);
  }
}
