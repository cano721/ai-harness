import { Command } from 'commander';
import { join } from 'path';
import chalk from 'chalk';
import { log } from '../utils/logger.js';
import { aggregateMetrics } from '../engine/metrics-aggregator.js';

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

export function registerMetrics(program: Command): void {
  program
    .command('metrics')
    .description('사용 메트릭을 집계하여 표시합니다')
    .option('--period <duration>', '기간 지정 (예: 7d, 2w, 30d)')
    .action(async (options: { period?: string }) => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const logDir = join(harnessDir, 'logs');

      let from: string | undefined;
      let to: string | undefined;

      if (options.period) {
        const parsed = parsePeriodArg(options.period);
        from = parsed.from;
        to = parsed.to;
      }

      const metrics = await aggregateMetrics(logDir, from, to);

      log.heading('AI Harness 메트릭');
      console.log(chalk.dim(`기간: ${metrics.period.from} ~ ${metrics.period.to}`));

      // 채택 지표
      log.heading('채택');
      log.info(`총 이벤트: ${chalk.bold(metrics.adoption.total_events)}건`);
      log.info(`활성 일수: ${chalk.bold(metrics.adoption.active_days)}일`);

      // 안전 지표
      log.heading('안전');
      log.info(`총 검사: ${chalk.bold(metrics.safety.total_checks)}건`);
      if (metrics.safety.blocked_count > 0) {
        log.warn(`차단: ${chalk.bold(metrics.safety.blocked_count)}건`);
      } else {
        log.success(`차단: ${chalk.bold(metrics.safety.blocked_count)}건`);
      }
      const blockRateColor = metrics.safety.block_rate > 10 ? chalk.red : chalk.green;
      console.log(`  ${chalk.blue('ℹ')} 차단율: ${blockRateColor(`${metrics.safety.block_rate}%`)}`);

      // 효율 지표
      log.heading('효율');
      if (metrics.efficiency.avg_hook_time_ms !== undefined) {
        log.info(`평균 훅 실행 시간: ${chalk.bold(metrics.efficiency.avg_hook_time_ms)}ms`);
      } else {
        log.info('훅 실행 시간 데이터 없음');
      }

      // 비용 지표
      log.heading('비용');
      log.info(`총 비용: ${formatUsd(metrics.cost.total_usd)}`);
      log.info(`이벤트 수: ${metrics.cost.event_count}건`);
      const modelEntries = Object.entries(metrics.cost.by_model);
      if (modelEntries.length > 0) {
        console.log(chalk.dim('  모델별:'));
        for (const [model, cost] of modelEntries) {
          console.log(`    ${chalk.cyan(model)}: ${formatUsd(cost)}`);
        }
      }
    });
}
