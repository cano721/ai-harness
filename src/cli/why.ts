import { Command } from 'commander';
import { readFile } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { log } from '../utils/logger.js';
import { AuditLogEntry } from '../types/index.js';

function getTodayLogPath(harnessDir: string): string {
  const today = new Date().toISOString().slice(0, 10);
  return join(harnessDir, 'logs', `${today}.jsonl`);
}

async function findLastBlockedEntry(logPath: string): Promise<AuditLogEntry | null> {
  if (!existsSync(logPath)) return null;
  const raw = await readFile(logPath, 'utf-8');
  const lines = raw.split('\n').filter((l) => l.trim().length > 0);
  let last: AuditLogEntry | null = null;
  for (const line of lines) {
    try {
      const entry = JSON.parse(line) as AuditLogEntry;
      if (entry.result === 'blocked') last = entry;
    } catch {}
  }
  return last;
}

export function registerWhy(program: Command): void {
  program
    .command('why')
    .description('가장 최근 차단 사유를 표시합니다')
    .action(async () => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const logPath = getTodayLogPath(harnessDir);

      log.heading('마지막 차단 이벤트');

      const entry = await findLastBlockedEntry(logPath);
      if (!entry) {
        log.info('오늘 차단 이벤트가 없습니다.');
        return;
      }

      log.info(`Hook    : ${entry.hook ?? '(알 수 없음)'}`);
      log.info(`Tool    : ${entry.tool ?? '(알 수 없음)'}`);
      log.info(`Action  : ${entry.action}`);
      log.info(`시각    : ${entry.timestamp}`);
      if (entry.reason) {
        log.warn(`사유    : ${entry.reason}`);
      }
      log.info('대안    : 허용된 경로를 사용하거나 팀 관리자에게 규칙 변경을 요청하세요.');
    });
}
