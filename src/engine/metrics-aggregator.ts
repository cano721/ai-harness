import { readFile, readdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { CostSummary, calculatePeriodCost } from './cost-tracker.js';

export interface MetricsSummary {
  adoption: { total_events: number; active_days: number };
  safety: { blocked_count: number; total_checks: number; block_rate: number };
  efficiency: { avg_hook_time_ms?: number };
  cost: CostSummary;
  period: { from: string; to: string };
}

interface AuditEntry {
  timestamp?: string;
  event_type?: string;
  result?: string;
  duration_ms?: number;
}

export async function aggregateMetrics(logDir: string, from?: string, to?: string): Promise<MetricsSummary> {
  const toDate = to ?? new Date().toISOString().slice(0, 10);
  const fromDate = from ?? new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

  if (!existsSync(logDir)) {
    return {
      adoption: { total_events: 0, active_days: 0 },
      safety: { blocked_count: 0, total_checks: 0, block_rate: 0 },
      efficiency: {},
      cost: { total_usd: 0, by_model: {}, event_count: 0, period: `${fromDate} ~ ${toDate}` },
      period: { from: fromDate, to: toDate },
    };
  }

  const files = await readdir(logDir);
  const jsonlFiles = files.filter((f) => f.endsWith('.jsonl'));

  const rangeFrom = new Date(fromDate);
  const rangeTo = new Date(toDate);

  const activeDaysSet = new Set<string>();
  let totalEvents = 0;
  let blockedCount = 0;
  let totalChecks = 0;
  const hookDurations: number[] = [];

  for (const file of jsonlFiles) {
    const dateStr = file.replace('.jsonl', '');
    const fileDate = new Date(dateStr);
    if (fileDate < rangeFrom || fileDate > rangeTo) continue;

    const raw = await readFile(join(logDir, file), 'utf-8');
    const lines = raw.split('\n').filter((l) => l.trim().length > 0);

    for (const line of lines) {
      try {
        const entry = JSON.parse(line) as AuditEntry;
        totalEvents++;
        activeDaysSet.add(dateStr);

        if (entry.result === 'blocked') {
          blockedCount++;
        }
        if (entry.event_type === 'hook_trigger') {
          totalChecks++;
          if (entry.duration_ms !== undefined) {
            hookDurations.push(entry.duration_ms);
          }
        }
      } catch {
        // 파싱 실패 라인 무시
      }
    }
  }

  const block_rate = totalChecks > 0 ? Math.round((blockedCount / totalChecks) * 10000) / 100 : 0;
  const avg_hook_time_ms =
    hookDurations.length > 0
      ? Math.round(hookDurations.reduce((a, b) => a + b, 0) / hookDurations.length)
      : undefined;

  const cost = await calculatePeriodCost(logDir, fromDate, toDate);

  return {
    adoption: { total_events: totalEvents, active_days: activeDaysSet.size },
    safety: { blocked_count: blockedCount, total_checks: totalChecks, block_rate },
    efficiency: avg_hook_time_ms !== undefined ? { avg_hook_time_ms } : {},
    cost,
    period: { from: fromDate, to: toDate },
  };
}
