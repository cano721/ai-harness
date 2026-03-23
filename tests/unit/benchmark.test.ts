import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, rm, writeFile, chmod } from 'fs/promises';
import { join } from 'path';
import { tmpdir } from 'os';
import { calculatePercentiles, benchmarkHook } from '../../src/engine/benchmark.js';

let tempDir: string;

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), 'ai-harness-bench-test-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('benchmark', () => {
  describe('calculatePercentiles', () => {
    it('정렬된 배열에서 p50/p95/p99를 계산한다', () => {
      // 10개 원소: [10,20,30,40,50,60,70,80,90,100]
      // p50: ceil(0.5*10)-1 = 4 → 50
      // p95: ceil(0.95*10)-1 = ceil(9.5)-1 = 9 → 100
      // p99: ceil(0.99*10)-1 = ceil(9.9)-1 = 9 → 100
      const times = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
      const { p50, p95, p99 } = calculatePercentiles(times);

      expect(p50).toBe(50);
      expect(p95).toBe(100);
      expect(p99).toBe(100);
    });

    it('단일 값 배열을 처리한다', () => {
      const { p50, p95, p99 } = calculatePercentiles([42]);
      expect(p50).toBe(42);
      expect(p95).toBe(42);
      expect(p99).toBe(42);
    });

    it('빈 배열은 모두 0을 반환한다', () => {
      const { p50, p95, p99 } = calculatePercentiles([]);
      expect(p50).toBe(0);
      expect(p95).toBe(0);
      expect(p99).toBe(0);
    });

    it('p50 <= p95 <= p99 순서를 보장한다', () => {
      const times = [5, 1, 9, 3, 7, 2, 8, 4, 6, 100];
      const { p50, p95, p99 } = calculatePercentiles(times);
      expect(p50).toBeLessThanOrEqual(p95);
      expect(p95).toBeLessThanOrEqual(p99);
    });

    it('중복 값 배열을 처리한다', () => {
      const times = [10, 10, 10, 10, 10];
      const { p50, p95, p99 } = calculatePercentiles(times);
      expect(p50).toBe(10);
      expect(p95).toBe(10);
      expect(p99).toBe(10);
    });

    it('입력 배열 순서를 변경하지 않는다 (사이드 이펙트 없음)', () => {
      const times = [100, 1, 50];
      const copy = [...times];
      calculatePercentiles(times);
      expect(times).toEqual(copy);
    });
  });

  describe('benchmarkHook', () => {
    it('실제 Hook 실행 시간이 0ms보다 크다', async () => {
      const hookPath = join(tempDir, 'test-hook.sh');
      await writeFile(hookPath, '#!/bin/bash\nexit 0\n', 'utf-8');
      await chmod(hookPath, 0o755);

      const result = await benchmarkHook(hookPath, 3);

      expect(result.times_ms.length).toBe(3);
      for (const t of result.times_ms) {
        expect(t).toBeGreaterThan(0);
      }
    });

    it('BenchmarkResult에 필수 필드가 모두 존재한다', async () => {
      const hookPath = join(tempDir, 'noop-hook.sh');
      await writeFile(hookPath, '#!/bin/bash\nexit 0\n', 'utf-8');
      await chmod(hookPath, 0o755);

      const result = await benchmarkHook(hookPath, 5);

      expect(result.hookName).toBeTruthy();
      expect(result.iterations).toBe(5);
      expect(result.times_ms.length).toBe(5);
      expect(typeof result.p50).toBe('number');
      expect(typeof result.p95).toBe('number');
      expect(typeof result.p99).toBe('number');
      expect(typeof result.min).toBe('number');
      expect(typeof result.max).toBe('number');
      expect(typeof result.avg).toBe('number');
    });

    it('min <= avg <= max 순서를 보장한다', async () => {
      const hookPath = join(tempDir, 'minmax-hook.sh');
      await writeFile(hookPath, '#!/bin/bash\nexit 0\n', 'utf-8');
      await chmod(hookPath, 0o755);

      const result = await benchmarkHook(hookPath, 5);

      expect(result.min).toBeLessThanOrEqual(result.avg);
      expect(result.avg).toBeLessThanOrEqual(result.max);
    });

    it('hookName이 파일명으로 설정된다', async () => {
      const hookPath = join(tempDir, 'my-special-hook.sh');
      await writeFile(hookPath, '#!/bin/bash\nexit 0\n', 'utf-8');
      await chmod(hookPath, 0o755);

      const result = await benchmarkHook(hookPath, 1);

      expect(result.hookName).toBe('my-special-hook.sh');
    });
  });
});
