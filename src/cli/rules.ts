import { Command } from 'commander';
import { join } from 'path';
import { log } from '../utils/logger.js';
import { loadConfig, loadLockPolicy } from '../engine/config-loader.js';

export function registerRules(program: Command): void {
  program
    .command('rules')
    .description('현재 적용 중인 규칙 목록을 표시합니다')
    .action(async () => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const configPath = join(harnessDir, 'config.yaml');
      const policyPath = join(harnessDir, 'lock-policy.yaml');

      log.heading('현재 적용 규칙');

      // 설정 로드
      let config;
      try {
        config = await loadConfig(configPath);
      } catch (err) {
        log.error(`config.yaml 로드 실패: ${(err as Error).message}`);
        process.exit(1);
      }

      // Hook 규칙
      log.heading('Hook 규칙');
      const hookEntries = Object.entries(config.hooks);
      if (hookEntries.length === 0) {
        log.info('등록된 Hook 규칙이 없습니다.');
      } else {
        for (const [name, override] of hookEntries) {
          const status = override.enabled ? '활성' : '비활성';
          const reason = override.reason ? ` — ${override.reason}` : '';
          log.info(`  ${name}: ${status}${reason}`);
        }
      }

      // 일반 규칙
      log.heading('일반 규칙');
      const ruleEntries = Object.entries(config.rules);
      if (ruleEntries.length === 0) {
        log.info('등록된 규칙이 없습니다.');
      } else {
        for (const [key, value] of ruleEntries) {
          log.info(`  ${key}: ${JSON.stringify(value)}`);
        }
      }

      // Lock Policy
      log.heading('Lock Policy');
      let policy;
      try {
        policy = await loadLockPolicy(policyPath);
      } catch (err) {
        log.warn(`lock-policy.yaml 로드 실패: ${(err as Error).message}`);
        return;
      }

      log.heading('[Global - 잠금]');
      if (policy.locked.length === 0) {
        log.info('잠긴 항목이 없습니다.');
      } else {
        for (const item of policy.locked) {
          log.info(`  🔒 ${item}`);
        }
      }

      log.heading('[경계값 규칙]');
      const boundedEntries = Object.entries(policy.bounded);
      if (boundedEntries.length === 0) {
        log.info('경계값 규칙이 없습니다.');
      } else {
        for (const [key, rule] of boundedEntries) {
          const parts: string[] = [`기본값: ${rule.default}`];
          if (rule.min !== undefined) parts.push(`최소: ${rule.min}`);
          if (rule.max !== undefined) parts.push(`최대: ${rule.max}`);
          log.info(`  ${key} (${parts.join(', ')})`);
        }
      }

      log.heading('[자유 규칙]');
      if (policy.free.length === 0) {
        log.info('자유 규칙이 없습니다.');
      } else {
        for (const item of policy.free) {
          log.info(`  ✓ ${item}`);
        }
      }

      // 팀 목록
      log.heading('팀 목록');
      if (config.teams.length === 0) {
        log.info('등록된 팀이 없습니다.');
      } else {
        for (const team of config.teams) {
          log.info(`  • ${team}`);
        }
      }
    });
}
