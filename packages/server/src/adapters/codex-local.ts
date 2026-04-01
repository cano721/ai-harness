import { execSync } from 'child_process';
import type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from './adapter.interface.js';
import { runChildProcess, killProcess } from './process-runner.js';

export class CodexLocalAdapter implements AgentAdapter {
  type = 'codex_local';

  async detect(): Promise<AdapterDetectResult> {
    try {
      const version = execSync('codex --version', { encoding: 'utf-8', timeout: 5000 }).trim();
      return { installed: true, version, command: 'codex' };
    } catch {
      return { installed: false };
    }
  }

  async execute(opts: AdapterExecuteOptions): Promise<AdapterExecuteResult> {
    const args = [
      '--quiet',
      '--full-auto',
      opts.prompt,
    ];

    const result = await runChildProcess({
      runId: opts.runId,
      command: 'codex',
      args,
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
