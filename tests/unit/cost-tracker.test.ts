import { describe, it, expect } from 'vitest';
import { join } from 'path';
import { writeFile, mkdir, rm } from 'fs/promises';
import { existsSync } from 'fs';
import { tmpdir } from 'os';
import { loadCostRates, calculateSessionCost, calculatePeriodCost, checkLimits, CostLimits } from '../../src/engine/cost-tracker.js';

const FIXTURES = join(import.meta.dirname, '..', 'fixtures');

describe('cost-tracker', () => {
  describe('loadCostRates', () => {
    it('cost-rates.yaml를 로드하고 파싱한다', async () => {
      const rates = await loadCostRates(join(FIXTURES, 'sample-cost-rates.yaml'));
      expect(rates.models).toHaveProperty('claude-opus-4-6');
      expect(rates.models['claude-opus-4-6'].input_per_million).toBe(15.0);
      expect(rates.models['claude-sonnet-4-6'].output_per_million).toBe(15.0);
    });

    it('limits 필드를 포함한다', async () => {
      const rates = await loadCostRates(join(FIXTURES, 'sample-cost-rates.yaml'));
      expect(rates.limits.per_session_usd).toBe(5.0);
      expect(rates.limits.per_day_usd).toBe(20.0);
      expect(rates.limits.per_week_usd).toBe(100.0);
      expect(rates.limits.per_month_usd).toBe(300.0);
    });

    it('mode_overrides를 포함한다', async () => {
      const rates = await loadCostRates(join(FIXTURES, 'sample-cost-rates.yaml'));
      expect(rates.mode_overrides?.autopilot?.per_session_usd).toBe(10.0);
      expect(rates.mode_overrides?.ralph?.per_session_usd).toBe(15.0);
    });

    it('존재하지 않는 파일은 에러를 던진다', async () => {
      await expect(loadCostRates('/nonexistent/path.yaml')).rejects.toThrow();
    });
  });

  describe('calculateSessionCost', () => {
    it('sample-audit-log.jsonl에서 비용을 계산한다', async () => {
      // 임시 디렉토리에 고정 날짜로 로그 복사
      const tmpDir = join(tmpdir(), `ai-harness-test-${Date.now()}`);
      await mkdir(tmpDir, { recursive: true });

      const { readFile } = await import('fs/promises');
      const sampleLog = await readFile(join(FIXTURES, 'sample-audit-log.jsonl'), 'utf-8');
      const testDate = '2026-03-22';
      await writeFile(join(tmpDir, `${testDate}.jsonl`), sampleLog);

      try {
        const summary = await calculateSessionCost(tmpDir, testDate);
        // 0.05 + 0.01 (cost_usd 있음) + 0.01 (cost_usd 없는 항목 추정)
        expect(summary.total_usd).toBeGreaterThan(0);
        expect(summary.event_count).toBe(3);
        expect(summary.period).toBe(testDate);
      } finally {
        await rm(tmpDir, { recursive: true, force: true });
      }
    });

    it('로그 파일이 없으면 0을 반환한다', async () => {
      const summary = await calculateSessionCost('/nonexistent/logdir', '2026-01-01');
      expect(summary.total_usd).toBe(0);
      expect(summary.event_count).toBe(0);
    });

    it('cost_usd가 있는 항목의 합계를 정확히 계산한다', async () => {
      const tmpDir = join(tmpdir(), `ai-harness-test-${Date.now()}`);
      await mkdir(tmpDir, { recursive: true });

      const log = [
        JSON.stringify({ event_type: 'tool_use', cost_usd: 0.05, result: 'success' }),
        JSON.stringify({ event_type: 'tool_use', cost_usd: 0.03, result: 'success' }),
      ].join('\n');

      const testDate = '2026-03-20';
      await writeFile(join(tmpDir, `${testDate}.jsonl`), log);

      try {
        const summary = await calculateSessionCost(tmpDir, testDate);
        expect(summary.total_usd).toBe(0.08);
        expect(summary.event_count).toBe(2);
      } finally {
        await rm(tmpDir, { recursive: true, force: true });
      }
    });
  });

  describe('calculatePeriodCost', () => {
    it('기간 내 여러 파일을 합산한다', async () => {
      const tmpDir = join(tmpdir(), `ai-harness-test-${Date.now()}`);
      await mkdir(tmpDir, { recursive: true });

      const log1 = JSON.stringify({ event_type: 'tool_use', cost_usd: 0.05, result: 'success' });
      const log2 = JSON.stringify({ event_type: 'tool_use', cost_usd: 0.10, result: 'success' });

      await writeFile(join(tmpDir, '2026-03-20.jsonl'), log1);
      await writeFile(join(tmpDir, '2026-03-21.jsonl'), log2);

      try {
        const summary = await calculatePeriodCost(tmpDir, '2026-03-20', '2026-03-21');
        expect(summary.total_usd).toBe(0.15);
        expect(summary.event_count).toBe(2);
        expect(summary.period).toBe('2026-03-20 ~ 2026-03-21');
      } finally {
        await rm(tmpDir, { recursive: true, force: true });
      }
    });

    it('범위 밖의 파일은 제외한다', async () => {
      const tmpDir = join(tmpdir(), `ai-harness-test-${Date.now()}`);
      await mkdir(tmpDir, { recursive: true });

      const log = JSON.stringify({ event_type: 'tool_use', cost_usd: 0.05, result: 'success' });
      await writeFile(join(tmpDir, '2026-03-19.jsonl'), log);
      await writeFile(join(tmpDir, '2026-03-20.jsonl'), log);
      await writeFile(join(tmpDir, '2026-03-22.jsonl'), log);

      try {
        const summary = await calculatePeriodCost(tmpDir, '2026-03-20', '2026-03-20');
        expect(summary.event_count).toBe(1);
      } finally {
        await rm(tmpDir, { recursive: true, force: true });
      }
    });

    it('logDir가 없으면 0을 반환한다', async () => {
      const summary = await calculatePeriodCost('/nonexistent/dir', '2026-03-01', '2026-03-31');
      expect(summary.total_usd).toBe(0);
    });
  });

  describe('checkLimits', () => {
    const limits: CostLimits = {
      per_session_usd: 5.0,
      per_day_usd: 20.0,
      per_week_usd: 100.0,
      per_month_usd: 300.0,
    };

    it('비용이 낮으면 ok를 반환한다', () => {
      const status = checkLimits(1.0, limits);
      expect(status.level).toBe('ok');
    });

    it('75% 이상이면 warning을 반환한다', () => {
      const status = checkLimits(3.8, limits); // 76% of 5.0
      expect(status.level).toBe('warning');
    });

    it('90% 이상이면 pause를 반환한다', () => {
      const status = checkLimits(4.6, limits); // 92% of 5.0
      expect(status.level).toBe('pause');
    });

    it('100% 이상이면 exceeded를 반환한다', () => {
      const status = checkLimits(5.5, limits); // 110% of 5.0
      expect(status.level).toBe('exceeded');
    });

    it('percentage와 limit_value를 올바르게 반환한다', () => {
      const status = checkLimits(2.5, limits); // 50% of 5.0
      expect(status.percentage).toBe(50);
      expect(status.limit_value).toBe(5.0);
    });
  });
});
