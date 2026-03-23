import { Command } from 'commander';
import { join } from 'path';
import { log } from '../utils/logger.js';
import { createSnapshot, listSnapshots, restoreSnapshot, restoreLatest } from '../engine/snapshot-manager.js';
import chalk from 'chalk';

interface RollbackOptions {
  list?: boolean;
  id?: string;
}

export function registerRollback(program: Command): void {
  program
    .command('rollback')
    .description('설정을 이전 스냅샷으로 복원합니다')
    .option('--list', '저장된 스냅샷 목록을 표시합니다')
    .option('--id <snapshotId>', '특정 스냅샷 ID로 복원합니다')
    .action(async (options: RollbackOptions) => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');

      if (options.list) {
        log.heading('스냅샷 목록');
        const snapshots = await listSnapshots(harnessDir);
        if (snapshots.length === 0) {
          log.warn('저장된 스냅샷이 없습니다. 먼저 ai-harness init을 실행하세요.');
          return;
        }
        for (const snap of snapshots) {
          const date = new Date(snap.createdAt).toLocaleString('ko-KR');
          console.log(
            `  ${chalk.cyan(snap.id)}  ${chalk.gray(date)}  ${chalk.dim(`(${snap.files.length}개 파일)`)}`
          );
        }
        console.log('');
        log.info(`총 ${snapshots.length}개 스냅샷`);
        return;
      }

      if (options.id) {
        log.heading(`스냅샷 복원: ${options.id}`);
        try {
          // 복원 전 현재 상태를 자동 백업
          const backupId = await createSnapshot(harnessDir);
          log.info(`현재 상태를 백업했습니다 (ID: ${backupId})`);

          await restoreSnapshot(harnessDir, options.id);
          log.success(`스냅샷 ${options.id} 복원 완료`);
        } catch (err) {
          log.error(`복원 실패: ${(err as Error).message}`);
          process.exit(1);
        }
        return;
      }

      // 기본: 최신 스냅샷으로 복원
      log.heading('최신 스냅샷으로 복원');
      try {
        const snapshots = await listSnapshots(harnessDir);
        if (snapshots.length === 0) {
          log.warn('저장된 스냅샷이 없습니다. 먼저 ai-harness init을 실행하세요.');
          return;
        }

        // 복원 전 현재 상태를 자동 백업
        const backupId = await createSnapshot(harnessDir);
        log.info(`현재 상태를 백업했습니다 (ID: ${backupId})`);

        const restoredId = await restoreLatest(harnessDir);
        if (restoredId === null) {
          log.warn('복원할 스냅샷이 없습니다.');
        } else {
          log.success(`스냅샷 ${restoredId} 복원 완료`);
        }
      } catch (err) {
        log.error(`복원 실패: ${(err as Error).message}`);
        process.exit(1);
      }
    });
}
