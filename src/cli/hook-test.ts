import { Command } from 'commander';
import { existsSync } from 'fs';
import { join } from 'path';
import chalk from 'chalk';
import { log } from '../utils/logger.js';
import { testHook, testAll } from '../engine/hook-tester.js';

function printResults(hookName: string, results: { name: string; passed: boolean; output?: string }[]): void {
  const passed = results.filter((r) => r.passed).length;
  const total = results.length;
  const allPassed = passed === total;

  const icon = allPassed ? chalk.green('✔') : chalk.red('❌');
  console.log(`\n${icon} ${chalk.bold(hookName)}: ${passed}/${total} 통과`);

  for (const result of results) {
    const r = result.passed ? chalk.green('  ✔') : chalk.red('  ❌');
    console.log(`${r} ${result.name}`);
    if (!result.passed && result.output) {
      console.log(chalk.gray(`     출력: ${result.output.slice(0, 200)}`));
    }
  }
}

export function registerHookTest(program: Command): void {
  program
    .command('hook-test [hook-name]')
    .description('Hook 테스트를 실행합니다')
    .option('--all', '모든 Hook 테스트 실행')
    .action(async (hookName: string | undefined, options: { all?: boolean }) => {
      const cwd = process.cwd();
      const hooksDir = join(cwd, '.ai-harness', 'hooks');

      if (!existsSync(hooksDir)) {
        log.error(`hooks 디렉토리가 없습니다: ${hooksDir}`);
        log.info('`ai-harness init`을 먼저 실행하세요.');
        process.exit(1);
      }

      log.heading('Hook 테스트');

      // --all 또는 hook-name 없을 때 전체 실행
      if (options.all || !hookName) {
        try {
          const allResults = await testAll(hooksDir);

          if (allResults.size === 0) {
            log.warn('실행 가능한 Hook 테스트가 없습니다.');
            return;
          }

          let totalPassed = 0;
          let totalTests = 0;

          for (const [file, results] of allResults) {
            printResults(file, results);
            totalPassed += results.filter((r) => r.passed).length;
            totalTests += results.length;
          }

          console.log('');
          if (totalPassed === totalTests) {
            log.success(`전체 결과: ${totalPassed}/${totalTests} 통과`);
          } else {
            log.error(`전체 결과: ${totalPassed}/${totalTests} 통과`);
            process.exit(1);
          }
        } catch (err) {
          log.error(`테스트 실행 실패: ${(err as Error).message}`);
          process.exit(1);
        }
        return;
      }

      // 특정 hook 테스트
      const hookFileName = hookName.endsWith('.sh') ? hookName : `${hookName}.sh`;
      const hookPath = join(hooksDir, hookFileName);
      const testPath = join(hooksDir, hookFileName.replace('.sh', '.test.yaml'));

      if (!existsSync(hookPath)) {
        log.error(`Hook 파일을 찾을 수 없습니다: ${hookPath}`);
        process.exit(1);
      }

      if (!existsSync(testPath)) {
        log.error(`테스트 정의 파일을 찾을 수 없습니다: ${testPath}`);
        process.exit(1);
      }

      try {
        const results = await testHook(hookPath, testPath);
        printResults(hookFileName, results);

        const passed = results.filter((r) => r.passed).length;
        const total = results.length;

        console.log('');
        if (passed === total) {
          log.success(`${passed}/${total} 통과`);
        } else {
          log.error(`${passed}/${total} 통과`);
          process.exit(1);
        }
      } catch (err) {
        log.error(`테스트 실행 실패: ${(err as Error).message}`);
        process.exit(1);
      }
    });
}
