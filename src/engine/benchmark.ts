import { readdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { spawn } from 'child_process';

export interface BenchmarkResult {
  hookName: string;
  iterations: number;
  times_ms: number[];
  p50: number;
  p95: number;
  p99: number;
  min: number;
  max: number;
  avg: number;
}

export interface Percentiles {
  p50: number;
  p95: number;
  p99: number;
}

export function calculatePercentiles(times: number[]): Percentiles {
  const sorted = [...times].sort((a, b) => a - b);
  const len = sorted.length;

  function percentile(p: number): number {
    if (len === 0) return 0;
    const idx = Math.ceil((p / 100) * len) - 1;
    return sorted[Math.max(0, Math.min(idx, len - 1))];
  }

  return {
    p50: percentile(50),
    p95: percentile(95),
    p99: percentile(99),
  };
}

function runHookOnce(hookPath: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const start = process.hrtime.bigint();
    const child = spawn('bash', [hookPath, 'Bash', 'test input'], {
      stdio: 'ignore',
      timeout: 10_000,
    });

    child.on('error', reject);
    child.on('close', () => {
      const end = process.hrtime.bigint();
      const elapsedMs = Number(end - start) / 1_000_000;
      resolve(elapsedMs);
    });
  });
}

export async function benchmarkHook(hookPath: string, iterations: number): Promise<BenchmarkResult> {
  const hookName = hookPath.split('/').pop() ?? hookPath;
  const times_ms: number[] = [];

  for (let i = 0; i < iterations; i++) {
    const elapsed = await runHookOnce(hookPath);
    times_ms.push(elapsed);
  }

  const { p50, p95, p99 } = calculatePercentiles(times_ms);
  const min = Math.min(...times_ms);
  const max = Math.max(...times_ms);
  const avg = times_ms.reduce((a, b) => a + b, 0) / times_ms.length;

  return { hookName, iterations, times_ms, p50, p95, p99, min, max, avg };
}

export async function benchmarkAll(
  hooksDir: string,
  iterations: number
): Promise<Map<string, BenchmarkResult>> {
  const results = new Map<string, BenchmarkResult>();

  if (!existsSync(hooksDir)) return results;

  const files = await readdir(hooksDir);
  const hookFiles = files.filter((f) => f.endsWith('.sh'));

  for (const hookFile of hookFiles) {
    const hookPath = join(hooksDir, hookFile);
    const result = await benchmarkHook(hookPath, iterations);
    results.set(hookFile, result);
  }

  return results;
}
