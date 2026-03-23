import { Command } from 'commander';
import { readFile } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { execSync } from 'child_process';
import { log } from '../utils/logger.js';
import { loadConfig, loadLockPolicy } from '../engine/config-loader.js';
import { validateConfig } from '../engine/lock-enforcer.js';
import { hasHarnessSection } from '../engine/claudemd-injector.js';
import { getRegisteredHooks } from '../engine/settings-manager.js';
import chalk from 'chalk';

function check(label: string, ok: boolean, detail?: string): void {
  const icon = ok ? chalk.green('✔') : chalk.red('❌');
  const msg = detail ? `${label} — ${detail}` : label;
  console.log(`  ${icon} ${msg}`);
}

function checkCommand(cmd: string): boolean {
  try {
    execSync(`which ${cmd}`, { stdio: 'ignore' });
    return true;
  } catch {
    try {
      execSync(`command -v ${cmd}`, { stdio: 'ignore', shell: '/bin/sh' });
      return true;
    } catch {
      return false;
    }
  }
}

function getNodeMajorVersion(): number {
  return parseInt(process.version.replace('v', '').split('.')[0], 10);
}

export function registerDoctor(program: Command): void {
  program
    .command('doctor')
    .description('환경 및 설정 진단을 실행합니다')
    .action(async () => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const configPath = join(harnessDir, 'config.yaml');
      const policyPath = join(harnessDir, 'lock-policy.yaml');
      const hooksDir = join(harnessDir, 'hooks');
      const claudeMdPath = join(cwd, 'CLAUDE.md');
      const settingsPath = join(cwd, '.claude', 'settings.json');

      let allOk = true;
      const fail = () => { allOk = false; };

      // ── 환경 검증 ──────────────────────────────────────────────
      log.heading('환경 검증');

      const nodeMajor = getNodeMajorVersion();
      const nodeOk = nodeMajor >= 18;
      check(`Node.js ${process.version}`, nodeOk, nodeOk ? '' : 'Node.js 18 이상 필요');
      if (!nodeOk) fail();

      const gitOk = checkCommand('git');
      check('Git', gitOk, gitOk ? '' : 'git이 PATH에 없습니다');
      if (!gitOk) fail();

      const claudeOk = checkCommand('claude');
      check('Claude Code', claudeOk, claudeOk ? '' : '설치되지 않았거나 PATH에 없습니다 (선택사항)');

      // ── 하네스 설정 검증 ────────────────────────────────────────
      log.heading('하네스 설정 검증');

      const configOk = existsSync(configPath);
      check('config.yaml 존재', configOk);
      if (!configOk) {
        fail();
      } else {
        try {
          const config = await loadConfig(configPath);
          check('config.yaml 파싱', true);

          const policy = await loadLockPolicy(policyPath);
          const violations = validateConfig(config, policy);
          if (violations.length === 0) {
            check('lock-policy 준수', true);
          } else {
            check('lock-policy 준수', false, `위반 ${violations.length}건`);
            for (const v of violations) {
              console.log(chalk.red(`    • ${v.key}: ${v.reason}`));
            }
            fail();
          }
        } catch (err) {
          check('config.yaml 파싱', false, (err as Error).message);
          fail();
        }
      }

      // ── Hook 검증 ───────────────────────────────────────────────
      log.heading('Hook 검증');

      const hookFiles = ['block-dangerous.sh', 'secret-scanner.sh', 'audit-logger.sh'];
      let registeredHooks: { matcher: string; command: string }[] = [];
      try {
        registeredHooks = await getRegisteredHooks(settingsPath);
      } catch {}

      for (const hookFile of hookFiles) {
        const hookPath = join(hooksDir, hookFile);
        const fileExists = existsSync(hookPath);
        check(`${hookFile} 존재`, fileExists);
        if (!fileExists) { fail(); continue; }

        // 실행 권한 확인
        let execOk = false;
        try {
          execSync(`test -x "${hookPath}"`, { stdio: 'ignore' });
          execOk = true;
        } catch {}
        check(`${hookFile} 실행 권한`, execOk);
        if (!execOk) fail();

        // settings.json 등록 여부
        const registered = registeredHooks.some((h) => h.command.includes(hookFile));
        check(`${hookFile} settings.json 등록`, registered);
        if (!registered) fail();
      }

      // ── CLAUDE.md 검증 ──────────────────────────────────────────
      log.heading('CLAUDE.md 검증');

      const claudeMdExists = existsSync(claudeMdPath);
      check('CLAUDE.md 존재', claudeMdExists);
      if (!claudeMdExists) {
        fail();
      } else {
        try {
          const content = await readFile(claudeMdPath, 'utf-8');
          const hasSection = hasHarnessSection(content);
          check('harness:start ~ harness:end 구간 존재', hasSection);
          if (!hasSection) fail();
        } catch (err) {
          check('CLAUDE.md 읽기', false, (err as Error).message);
          fail();
        }
      }

      // ── 최종 결과 ────────────────────────────────────────────────
      console.log('');
      if (allOk) {
        log.success('모든 검사를 통과했습니다.');
      } else {
        log.error('일부 검사가 실패했습니다. 위 항목을 확인하세요.');
        process.exit(1);
      }
    });
}
