import { Command } from 'commander';
import { readFile } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { log } from '../utils/logger.js';
import { loadConfig } from '../engine/config-loader.js';
import { getRegisteredHooks } from '../engine/settings-manager.js';

function getTodayLogPath(harnessDir: string): string {
  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  return join(harnessDir, 'logs', `${today}.jsonl`);
}

async function readAuditLog(logPath: string): Promise<{ total: number; blocked: number }> {
  if (!existsSync(logPath)) {
    return { total: 0, blocked: 0 };
  }
  const raw = await readFile(logPath, 'utf-8');
  const lines = raw.split('\n').filter((l) => l.trim().length > 0);
  let blocked = 0;
  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      if (entry.result === 'blocked') blocked++;
    } catch {}
  }
  return { total: lines.length, blocked };
}

export function registerStatus(program: Command): void {
  program
    .command('status')
    .description('AI Harness 현재 상태를 표시합니다')
    .action(async () => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const configPath = join(harnessDir, 'config.yaml');
      const settingsPath = join(cwd, '.claude', 'settings.json');

      log.heading('AI Harness 상태');

      // 설정 파일 확인
      if (!existsSync(configPath)) {
        log.error('config.yaml이 없습니다. `ai-harness init`을 먼저 실행하세요.');
        process.exit(1);
      }

      // 설정 로드
      let config;
      try {
        config = await loadConfig(configPath);
      } catch (err) {
        log.error(`config.yaml 로드 실패: ${(err as Error).message}`);
        process.exit(1);
      }

      // 팀 상태
      log.heading('팀');
      if (config.teams.length === 0) {
        log.info('등록된 팀이 없습니다.');
      } else {
        for (const team of config.teams) {
          log.success(team);
        }
      }

      // Guardrail 상태
      log.heading('가드레일');
      log.info(`최대 파일 변경: ${config.guardrails.max_files_changed}개`);
      log.info(`최대 비용: $${config.guardrails.max_cost_usd}`);
      log.info(`최대 실행 시간: ${config.guardrails.max_execution_minutes}분`);

      // Hook 상태
      log.heading('Hook');
      try {
        const hooks = await getRegisteredHooks(settingsPath);
        if (hooks.length === 0) {
          log.warn('등록된 Hook이 없습니다.');
        } else {
          for (const hook of hooks) {
            log.success(`${hook.command} (matcher: ${hook.matcher})`);
          }
        }
      } catch {
        log.warn('settings.json을 읽을 수 없습니다.');
      }

      // 오늘 감사 로그 요약
      log.heading('오늘 감사 로그');
      const logPath = getTodayLogPath(harnessDir);
      const { total, blocked } = await readAuditLog(logPath);
      log.info(`총 이벤트: ${total}건`);
      if (blocked > 0) {
        log.warn(`차단: ${blocked}건`);
      } else {
        log.success(`차단: ${blocked}건`);
      }
    });
}
