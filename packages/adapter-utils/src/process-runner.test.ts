import { describe, expect, it } from 'vitest';
import { runChildProcess, killProcess } from './process-runner.js';

describe('runChildProcess', () => {
  it('streams stdout and stderr', async () => {
    const logs: Array<{ stream: 'stdout' | 'stderr'; chunk: string }> = [];

    const result = await runChildProcess({
      runId: 'stream-test',
      command: process.execPath,
      args: ['-e', 'console.log("hello"); console.error("warn")'],
      cwd: process.cwd(),
      env: {},
      timeoutSec: 5,
      onLog: (stream, chunk) => {
        logs.push({ stream, chunk });
      },
    });

    expect(result.exitCode).toBe(0);
    expect(result.timedOut).toBe(false);
    expect(logs.some((log) => log.stream === 'stdout' && log.chunk.includes('hello'))).toBe(true);
    expect(logs.some((log) => log.stream === 'stderr' && log.chunk.includes('warn'))).toBe(true);
  });

  it('removes nested Claude env vars before spawning', async () => {
    const logs: string[] = [];

    const result = await runChildProcess({
      runId: 'env-test',
      command: process.execPath,
      args: [
        '-e',
        'console.log(JSON.stringify({ cc: process.env.CLAUDECODE ?? null, entry: process.env.CLAUDE_CODE_ENTRYPOINT ?? null }))',
      ],
      cwd: process.cwd(),
      env: {
        CLAUDECODE: '1',
        CLAUDE_CODE_ENTRYPOINT: 'nested',
      },
      timeoutSec: 5,
      onLog: (_stream, chunk) => {
        logs.push(chunk);
      },
    });

    expect(result.exitCode).toBe(0);
    expect(logs.join('')).toContain('"cc":null');
    expect(logs.join('')).toContain('"entry":null');
  });

  it('can kill a running process', async () => {
    const runPromise = runChildProcess({
      runId: 'kill-test',
      command: process.execPath,
      args: ['-e', 'setInterval(() => {}, 1000)'],
      cwd: process.cwd(),
      env: {},
      timeoutSec: 30,
      onLog: () => {},
    });

    const killed = killProcess('kill-test');
    const result = await runPromise;

    expect(killed).toBe(true);
    expect(result.exitCode === null || result.exitCode > 0).toBe(true);
  });
});
