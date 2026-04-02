import { execSync } from 'child_process';
import type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from '@ddalkak/adapter-utils';
import { runChildProcess, killProcess } from '@ddalkak/adapter-utils';

const CLAUDE_INPUT_COST_PER_M = 15.0;
const CLAUDE_OUTPUT_COST_PER_M = 75.0;
const CLAUDE_CACHE_READ_COST_PER_M = 1.5;

interface ClaudeJsonOutput {
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    cache_read_input_tokens?: number;
  };
}

export class ClaudeLocalAdapter implements AgentAdapter {
  type = 'claude_local';

  async detect(): Promise<AdapterDetectResult> {
    try {
      const version = execSync('claude --version', { encoding: 'utf-8', timeout: 5000 }).trim();
      return { installed: true, version, command: 'claude' };
    } catch {
      return { installed: false };
    }
  }

  async execute(opts: AdapterExecuteOptions): Promise<AdapterExecuteResult> {
    const args = [
      '--print',
      '--output-format', 'json',
      '--max-turns', String(opts.maxTurns ?? 20),
      '--dangerously-skip-permissions',
      opts.prompt,
    ];

    const stdoutChunks: string[] = [];

    const result = await runChildProcess({
      runId: opts.runId,
      command: 'claude',
      args,
      cwd: opts.cwd,
      env: opts.env,
      timeoutSec: opts.timeoutSec,
      onLog: (stream, chunk) => {
        if (stream === 'stdout') {
          stdoutChunks.push(chunk);
        }
        opts.onLog(stream, chunk);
      },
      onSpawn: opts.onSpawn,
    });

    let usage: AdapterExecuteResult['usage'];
    let costUsd: number | undefined;

    try {
      const parsed: ClaudeJsonOutput = JSON.parse(stdoutChunks.join(''));
      if (parsed.usage) {
        const inputTokens = parsed.usage.input_tokens ?? 0;
        const outputTokens = parsed.usage.output_tokens ?? 0;
        const cachedTokens = parsed.usage.cache_read_input_tokens ?? 0;
        usage = { inputTokens, outputTokens, cachedTokens };
        costUsd =
          (inputTokens / 1_000_000) * CLAUDE_INPUT_COST_PER_M +
          (outputTokens / 1_000_000) * CLAUDE_OUTPUT_COST_PER_M +
          (cachedTokens / 1_000_000) * CLAUDE_CACHE_READ_COST_PER_M;
      }
    } catch {
      // Best effort only. Some runs may not expose structured usage output.
    }

    return {
      exitCode: result.exitCode,
      signal: result.signal,
      timedOut: result.timedOut,
      usage,
      costUsd,
    };
  }

  kill(runId: string): void {
    killProcess(runId);
  }
}
