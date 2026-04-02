import { execSync } from 'child_process';
import type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from './adapter.interface.js';
import { runChildProcess, killProcess } from './process-runner.js';

// GPT-4o pricing (per 1M tokens, USD) — used as Codex default
const CODEX_INPUT_COST_PER_M = 2.5;
const CODEX_OUTPUT_COST_PER_M = 10.0;

// Codex CLI may print token summary lines like:
//   "Tokens used: 1234 input, 567 output"
// or JSON with usage field
function parseCodexUsage(stdout: string): AdapterExecuteResult['usage'] | undefined {
  // Try JSON parse first
  try {
    const parsed = JSON.parse(stdout);
    if (parsed?.usage) {
      return {
        inputTokens: parsed.usage.input_tokens ?? parsed.usage.prompt_tokens ?? 0,
        outputTokens: parsed.usage.output_tokens ?? parsed.usage.completion_tokens ?? 0,
      };
    }
  } catch {
    // not JSON
  }

  // Try plain text patterns
  const tokenMatch = stdout.match(/[Tt]okens?\s+used[:\s]+(\d+)\s+input[,\s]+(\d+)\s+output/);
  if (tokenMatch) {
    return { inputTokens: parseInt(tokenMatch[1], 10), outputTokens: parseInt(tokenMatch[2], 10) };
  }

  // OpenAI-style: "prompt_tokens: 123" / "completion_tokens: 456"
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
    const args = [
      '--quiet',
      '--full-auto',
      opts.prompt,
    ];

    const stdoutChunks: string[] = [];

    const result = await runChildProcess({
      runId: opts.runId,
      command: 'codex',
      args,
      cwd: opts.cwd,
      env: opts.env,
      timeoutSec: opts.timeoutSec,
      onLog: (stream, chunk) => {
        if (stream === 'stdout') stdoutChunks.push(chunk);
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
