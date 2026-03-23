import { Command } from 'commander';
import { join } from 'path';
import { existsSync } from 'fs';
import { log } from '../utils/logger.js';
import { benchmarkHook, benchmarkAll, BenchmarkResult } from '../engine/benchmark.js';
import chalk from 'chalk';

interface BenchmarkOptions {
  iterations?: string;
  hook?: string;
}

function formatMs(ms: number): string {
  return `${ms.toFixed(2)}ms`;
}

function printTable(results: BenchmarkResult[]): void {
  if (results.length === 0) {
    log.warn('벤치마크할 Hook이 없습니다.');
    return;
  }

  const COL = {
    name: 28,
    iter: 5,
    p50: 10,
    p95: 10,
    p99: 10,
    min: 10,
    max: 10,
    avg: 10,
  };

  const header = [
    chalk.bold('Hook'.padEnd(COL.name)),
    chalk.bold('N'.padStart(COL.iter)),
    chalk.bold('p50'.padStart(COL.p50)),
    chalk.bold('p95'.padStart(COL.p95)),
    chalk.bold('p99'.padStart(COL.p99)),
    chalk.bold('min'.padStart(COL.min)),
    chalk.bold('max'.padStart(COL.max)),
    chalk.bold('avg'.padStart(COL.avg)),
  ].join('  ');

  const divider = '─'.repeat(
    COL.name + COL.iter + COL.p50 + COL.p95 + COL.p99 + COL.min + COL.max + COL.avg + 14
  );

  console.log('');
  console.log(header);
  console.log(chalk.gray(divider));

  for (const r of results) {
    const row = [
      chalk.cyan(r.hookName.padEnd(COL.name)),
      String(r.iterations).padStart(COL.iter),
      formatMs(r.p50).padStart(COL.p50),
      formatMs(r.p95).padStart(COL.p95),
      chalk.yellow(formatMs(r.p99).padStart(COL.p99)),
      formatMs(r.min).padStart(COL.min),
      formatMs(r.max).padStart(COL.max),
      formatMs(r.avg).padStart(COL.avg),
    ].join('  ');
    console.log(row);
  }

  console.log('');
}

export function registerBenchmark(program: Command): void {
  program
    .command('benchmark')
    .description('Hook 실행 시간을 측정합니다')
    .option('--iterations <n>', '반복 횟수 (기본값: 10)', '10')
    .option('--hook <name>', '특정 Hook 이름만 벤치마크 (예: block-dangerous.sh)')
    .action(async (options: BenchmarkOptions) => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const hooksDir = join(harnessDir, 'hooks');
      const iterations = parseInt(options.iterations ?? '10', 10);

      if (isNaN(iterations) || iterations < 1) {
        log.error('반복 횟수는 1 이상의 정수여야 합니다.');
        process.exit(1);
      }

      log.heading(`Hook 벤치마크 (${iterations}회 반복)`);

      try {
        if (options.hook) {
          const hookPath = join(hooksDir, options.hook);
          if (!existsSync(hookPath)) {
            log.error(`Hook 파일을 찾을 수 없습니다: ${hookPath}`);
            process.exit(1);
          }
          log.info(`${options.hook} 벤치마크 중...`);
          const result = await benchmarkHook(hookPath, iterations);
          printTable([result]);
        } else {
          if (!existsSync(hooksDir)) {
            log.error(`.ai-harness/hooks 디렉토리가 없습니다. 먼저 ai-harness init을 실행하세요.`);
            process.exit(1);
          }
          log.info('모든 Hook 벤치마크 중...');
          const resultsMap = await benchmarkAll(hooksDir, iterations);
          printTable(Array.from(resultsMap.values()));
        }

        log.success('벤치마크 완료');
      } catch (err) {
        log.error(`벤치마크 실패: ${(err as Error).message}`);
        process.exit(1);
      }
    });
}
