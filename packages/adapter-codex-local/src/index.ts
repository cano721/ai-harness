import { execSync } from 'child_process';
import type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from '@ddalkak/adapter-utils';
import { runChildProcess, killProcess } from '@ddalkak/adapter-utils';

const CODEX_INPUT_COST_PER_M = 2.5;
const CODEX_OUTPUT_COST_PER_M = 10.0;

export function parseCodexUsage(stdout: string): AdapterExecuteResult['usage'] | undefined {
  try {
    const parsed = JSON.parse(stdout);
    if (parsed?.usage) {
      return {
        inputTokens: parsed.usage.input_tokens ?? parsed.usage.prompt_tokens ?? 0,
        outputTokens: parsed.usage.output_tokens ?? parsed.usage.completion_tokens ?? 0,
      };
    }
  } catch {
    // fall through to plaintext heuristics
  }

  const tokenMatch = stdout.match(/[Tt]okens?\s+used[:\s]+(\d+)\s+input[,\s]+(\d+)\s+output/);
  if (tokenMatch) {
    return { inputTokens: parseInt(tokenMatch[1], 10), outputTokens: parseInt(tokenMatch[2], 10) };
  }

  const promptMatch = stdout.match(/prompt_tokens[:\s]+(\d+)/);
  const completionMatch = stdout.match(/completion_tokens[:\s]+(\d+)/);
  if (promptMatch && completionMatch) {
    return { inputTokens: parseInt(promptMatch[1], 10), outputTokens: parseInt(completionMatch[1], 10) };
  }

  return undefined;
}

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
    const stdoutChunks: string[] = [];

    const result = await runChildProcess({
      runId: opts.runId,
      command: 'codex',
      args: ['--quiet', '--full-auto', opts.prompt],
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

    const usage = parseCodexUsage(stdoutChunks.join(''));
    const costUsd = usage
      ? (usage.inputTokens / 1_000_000) * CODEX_INPUT_COST_PER_M +
        (usage.outputTokens / 1_000_000) * CODEX_OUTPUT_COST_PER_M
      : undefined;

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
