import { readFile, readdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { parse } from 'yaml';

export interface CostRates {
  models: Record<string, { input_per_million: number; output_per_million: number }>;
  limits: CostLimits;
  mode_overrides?: Record<string, Partial<CostLimits>>;
}

export interface CostLimits {
  per_session_usd: number;
  per_day_usd: number;
  per_week_usd: number;
  per_month_usd: number;
}

export interface CostSummary {
  total_usd: number;
  by_model: Record<string, number>;
  event_count: number;
  period: string;
}

export interface LimitStatus {
  level: 'ok' | 'warning' | 'pause' | 'exceeded';
  percentage: number;
  limit_name: string;
  limit_value: number;
}

interface AuditEntry {
  timestamp?: string;
  event_type?: string;
  tool?: string;
  model?: string;
  cost_usd?: number;
  result?: string;
}

export async function loadCostRates(ratesPath: string): Promise<CostRates> {
  if (!existsSync(ratesPath)) {
    throw new Error(`비용 요율 파일을 찾을 수 없습니다: ${ratesPath}`);
  }
  const raw = await readFile(ratesPath, 'utf-8');
  return parse(raw) as CostRates;
}

function parseAuditLines(raw: string): AuditEntry[] {
  return raw
    .split('\n')
    .filter((l) => l.trim().length > 0)
    .map((line) => {
      try {
        return JSON.parse(line) as AuditEntry;
      } catch {
        return {};
      }
    });
}

function summarizeEntries(entries: AuditEntry[], period: string): CostSummary {
  const by_model: Record<string, number> = {};
  let total_usd = 0;

  for (const entry of entries) {
    if (entry.cost_usd !== undefined) {
      total_usd += entry.cost_usd;
      const model = entry.model ?? 'unknown';
      by_model[model] = (by_model[model] ?? 0) + entry.cost_usd;
    } else {
      // 비용 필드가 없는 이벤트는 이벤트당 $0.01로 추정
      total_usd += 0.01;
      const model = entry.model ?? 'unknown';
      by_model[model] = (by_model[model] ?? 0) + 0.01;
    }
  }

  return {
    total_usd: Math.round(total_usd * 10000) / 10000,
    by_model,
    event_count: entries.length,
    period,
  };
}

export async function calculateSessionCost(logDir: string, sessionDate?: string): Promise<CostSummary> {
  const date = sessionDate ?? new Date().toISOString().slice(0, 10);
  const logPath = join(logDir, `${date}.jsonl`);

  if (!existsSync(logPath)) {
    return { total_usd: 0, by_model: {}, event_count: 0, period: date };
  }

  const raw = await readFile(logPath, 'utf-8');
  const entries = parseAuditLines(raw);
  return summarizeEntries(entries, date);
}

export async function calculatePeriodCost(logDir: string, from: string, to: string): Promise<CostSummary> {
  if (!existsSync(logDir)) {
    return { total_usd: 0, by_model: {}, event_count: 0, period: `${from} ~ ${to}` };
  }

  const files = await readdir(logDir);
  const jsonlFiles = files.filter((f) => f.endsWith('.jsonl'));

  const fromDate = new Date(from);
  const toDate = new Date(to);

  const allEntries: AuditEntry[] = [];

  for (const file of jsonlFiles) {
    const dateStr = file.replace('.jsonl', '');
    const fileDate = new Date(dateStr);
    if (fileDate >= fromDate && fileDate <= toDate) {
      const raw = await readFile(join(logDir, file), 'utf-8');
      allEntries.push(...parseAuditLines(raw));
    }
  }

  return summarizeEntries(allEntries, `${from} ~ ${to}`);
}

export function checkLimits(cost: number, limits: CostLimits): LimitStatus {
  const checks: Array<{ name: string; value: number }> = [
    { name: 'per_session_usd', value: limits.per_session_usd },
    { name: 'per_day_usd', value: limits.per_day_usd },
    { name: 'per_week_usd', value: limits.per_week_usd },
    { name: 'per_month_usd', value: limits.per_month_usd },
  ];

  const severity = ['ok', 'warning', 'pause', 'exceeded'];
  let mostSevere: LimitStatus = {
    level: 'ok',
    percentage: Math.round((cost / checks[0].value) * 1000) / 10,
    limit_name: checks[0].name,
    limit_value: checks[0].value,
  };

  for (const check of checks) {
    const percentage = (cost / check.value) * 100;
    let level: LimitStatus['level'] = 'ok';

    if (percentage >= 100) {
      level = 'exceeded';
    } else if (percentage >= 90) {
      level = 'pause';
    } else if (percentage >= 75) {
      level = 'warning';
    }

    if (severity.indexOf(level) > severity.indexOf(mostSevere.level)) {
      mostSevere = { level, percentage: Math.round(percentage * 10) / 10, limit_name: check.name, limit_value: check.value };
    }
  }

  return mostSevere;
}
