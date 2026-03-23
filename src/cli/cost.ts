import { Command } from 'commander';
import { join } from 'path';
import chalk from 'chalk';
import { log } from '../utils/logger.js';
import { loadCostRates, calculateSessionCost, calculatePeriodCost, checkLimits, CostSummary } from '../engine/cost-tracker.js';

function formatUsd(amount: number): string {
  return chalk.yellow(`$${amount.toFixed(4)}`);
}

function parsePeriodArg(period: string): { from: string; to: string } {
  const to = new Date().toISOString().slice(0, 10);
  const match = period.match(/^(\d+)d$/);
  if (match) {
    const days = parseInt(match[1], 10);
    const from = new Date(Date.now() - (days - 1) * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    return { from, to };
  }
  const weekMatch = period.match(/^(\d+)w$/);
  if (weekMatch) {
    const weeks = parseInt(weekMatch[1], 10);
    const from = new Date(Date.now() - weeks * 7 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    return { from, to };
  }
  return { from: to, to };
}

function printCostSummary(summary: CostSummary, label: string): void {
  log.heading(label);
  log.info(`기간: ${summary.period}`);
  log.info(`총 이벤트: ${summary.event_count}건`);
  console.log(chalk.bold(`총 비용: ${formatUsd(summary.total_usd)}`));
}

function printByModel(summary: CostSummary): void {
  log.heading('모델별 비용');
  const entries = Object.entries(summary.by_model);
  if (entries.length === 0) {
    log.info('모델 정보 없음');
    return;
  }
  for (const [model, cost] of entries) {
    console.log(`  ${chalk.cyan(model)}: ${formatUsd(cost)}`);
  }
}

export function registerCost(program: Command): void {
  program
    .command('cost')
    .description('비용 사용 현황을 표시합니다')
    .option('--daily', '일별 상세 표시')
    .option('--period <duration>', '기간 지정 (예: 7d, 2w)')
    .option('--by <dimension>', '차원별 표시 (model)')
    .action(async (options: { daily?: boolean; period?: string; by?: string }) => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const logDir = join(harnessDir, 'logs');
      const ratesPath = join(cwd, 'templates', 'cost-rates.yaml');

      let rates;
      try {
        rates = await loadCostRates(ratesPath);
      } catch {
        // 요율 파일 없어도 비용 표시는 가능
        rates = null;
      }

      if (options.period) {
        const { from, to } = parsePeriodArg(options.period);
        const summary = await calculatePeriodCost(logDir, from, to);
        printCostSummary(summary, `비용 요약 (${options.period})`);
        if (options.by === 'model') printByModel(summary);
      } else if (options.daily) {
        // 최근 7일 일별 상세
        log.heading('일별 비용 (최근 7일)');
        let grandTotal = 0;
        for (let i = 6; i >= 0; i--) {
          const date = new Date(Date.now() - i * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
          const summary = await calculateSessionCost(logDir, date);
          grandTotal += summary.total_usd;
          console.log(`  ${chalk.cyan(date)}: ${formatUsd(summary.total_usd)} (${summary.event_count}건)`);
        }
        console.log(chalk.bold(`\n합계: ${formatUsd(grandTotal)}`));
      } else {
        // 기본: 오늘 비용
        const today = new Date().toISOString().slice(0, 10);
        const summary = await calculateSessionCost(logDir, today);
        printCostSummary(summary, '오늘 비용 요약');

        if (options.by === 'model') printByModel(summary);

        if (rates) {
          const status = checkLimits(summary.total_usd, rates.limits);
          log.heading('한도 상태');
          const levelColors: Record<string, (s: string) => string> = {
            ok: chalk.green,
            warning: chalk.yellow,
            pause: chalk.red,
            exceeded: chalk.bgRed,
          };
          const color = levelColors[status.level] ?? chalk.white;
          console.log(
            `  ${color(status.level.toUpperCase())} — ${status.limit_name}: ${formatUsd(summary.total_usd)} / ${formatUsd(status.limit_value)} (${status.percentage}%)`
          );
        }
      }
    });
}
