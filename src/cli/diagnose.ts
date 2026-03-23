import { Command } from 'commander';
import { readFile, readdir, stat } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { execSync } from 'child_process';
import chalk from 'chalk';
import { log } from '../utils/logger.js';
import { loadConfig, loadLockPolicy } from '../engine/config-loader.js';
import { validateConfig } from '../engine/lock-enforcer.js';
import { hasHarnessSection } from '../engine/claudemd-injector.js';
import { getRegisteredHooks } from '../engine/settings-manager.js';

type CheckStatus = 'ok' | 'warn' | 'error';

interface CheckItem {
  label: string;
  status: CheckStatus;
  detail?: string;
}

function icon(status: CheckStatus): string {
  if (status === 'ok') return chalk.green('✔');
  if (status === 'warn') return chalk.yellow('⚠');
  return chalk.red('❌');
}

function printCheck(item: CheckItem): void {
  const detail = item.detail ? chalk.gray(` — ${item.detail}`) : '';
  console.log(`  ${icon(item.status)} ${item.label}${detail}`);
}

function runCommand(cmd: string): string | null {
  try {
    return execSync(cmd, { stdio: 'pipe' }).toString().trim();
  } catch {
    return null;
  }
}

function commandVersion(cmd: string, versionFlag = '--version'): string | null {
  return runCommand(`${cmd} ${versionFlag}`);
}

async function dirSizeBytes(dirPath: string): Promise<number> {
  if (!existsSync(dirPath)) return 0;
  let total = 0;
  const entries = await readdir(dirPath, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dirPath, entry.name);
    if (entry.isDirectory()) {
      total += await dirSizeBytes(full);
    } else {
      const s = await stat(full);
      total += s.size;
    }
  }
  return total;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
}

function getDiskFree(path: string): string | null {
  const out = runCommand(`df -h "${path}"`);
  if (!out) return null;
  const lines = out.split('\n');
  if (lines.length < 2) return null;
  const parts = lines[1].split(/\s+/);
  // available column is index 3 on macOS (Avail)
  return parts[3] ?? null;
}

export function registerDiagnose(program: Command): void {
  program
    .command('diagnose')
    .description('종합 진단을 실행합니다 (doctor보다 상세)')
    .action(async () => {
      const cwd = process.cwd();
      const harnessDir = join(cwd, '.ai-harness');
      const configPath = join(harnessDir, 'config.yaml');
      const policyPath = join(harnessDir, 'lock-policy.yaml');
      const hooksDir = join(harnessDir, 'hooks');
      const logsDir = join(harnessDir, 'logs');
      const claudeMdPath = join(cwd, 'CLAUDE.md');
      const settingsPath = join(cwd, '.claude', 'settings.json');

      let totalChecks = 0;
      let passedChecks = 0;
      const recommendations: string[] = [];

      function record(item: CheckItem): void {
        totalChecks++;
        if (item.status === 'ok') passedChecks++;
        printCheck(item);
        if (item.status === 'error' && item.detail) {
          recommendations.push(item.detail);
        }
      }

      // ── 1. 환경 ────────────────────────────────────────────────
      log.heading('환경');

      const nodeMajor = parseInt(process.version.replace('v', '').split('.')[0], 10);
      record({
        label: `Node.js ${process.version}`,
        status: nodeMajor >= 18 ? 'ok' : 'error',
        detail: nodeMajor >= 18 ? undefined : 'Node.js 18 이상으로 업그레이드하세요',
      });

      const gitVersion = commandVersion('git');
      record({
        label: `Git ${gitVersion ?? '(찾을 수 없음)'}`,
        status: gitVersion ? 'ok' : 'error',
        detail: gitVersion ? undefined : 'git을 설치하거나 PATH에 추가하세요',
      });

      const claudeVersion = commandVersion('claude');
      record({
        label: `Claude Code ${claudeVersion ?? '(찾을 수 없음)'}`,
        status: claudeVersion ? 'ok' : 'warn',
        detail: claudeVersion ? undefined : 'Claude Code가 설치되지 않았습니다 (선택사항)',
      });

      record({
        label: `OS: ${process.platform} ${process.arch}`,
        status: 'ok',
      });

      const diskFree = getDiskFree(cwd);
      record({
        label: `디스크 여유 공간: ${diskFree ?? '알 수 없음'}`,
        status: 'ok',
      });

      // ── 2. 설정 ────────────────────────────────────────────────
      log.heading('설정');

      const configExists = existsSync(configPath);
      record({
        label: 'config.yaml 존재',
        status: configExists ? 'ok' : 'error',
        detail: configExists ? undefined : 'ai-harness init을 실행하여 config.yaml을 생성하세요',
      });

      if (configExists) {
        try {
          const config = await loadConfig(configPath);
          record({
            label: `config.yaml 파싱 (스키마 v${config._schema_version})`,
            status: 'ok',
          });

          const policy = await loadLockPolicy(policyPath);
          const violations = validateConfig(config, policy);
          record({
            label: 'lock-policy 준수',
            status: violations.length === 0 ? 'ok' : 'error',
            detail: violations.length > 0
              ? `위반 ${violations.length}건: ${violations.map(v => v.key).join(', ')}`
              : undefined,
          });

          for (const v of violations) {
            console.log(chalk.red(`    • ${v.key}: ${v.reason}`));
          }
        } catch (err) {
          record({
            label: 'config.yaml 파싱',
            status: 'error',
            detail: `파싱 오류: ${(err as Error).message}`,
          });
        }
      }

      // ── 3. Hook ────────────────────────────────────────────────
      log.heading('Hook');

      let registeredHooks: { matcher: string; command: string }[] = [];
      try {
        registeredHooks = await getRegisteredHooks(settingsPath);
      } catch {}

      const expectedHooks = ['block-dangerous.sh', 'secret-scanner.sh', 'audit-logger.sh'];
      let hookFiles: string[] = [];

      if (existsSync(hooksDir)) {
        try {
          const entries = await readdir(hooksDir);
          hookFiles = entries.filter((f) => f.endsWith('.sh'));
        } catch {}
      }

      if (hookFiles.length === 0) {
        record({
          label: 'Hook 디렉토리',
          status: 'error',
          detail: 'ai-harness init을 실행하여 Hook을 설치하세요',
        });
      }

      for (const hookFile of expectedHooks) {
        const hookPath = join(hooksDir, hookFile);
        const fileExists = existsSync(hookPath);

        record({
          label: `${hookFile} 존재`,
          status: fileExists ? 'ok' : 'error',
          detail: fileExists ? undefined : `ai-harness init을 실행하여 ${hookFile}을 복원하세요`,
        });

        if (!fileExists) continue;

        let execOk = false;
        try {
          execSync(`test -x "${hookPath}"`, { stdio: 'ignore' });
          execOk = true;
        } catch {}
        record({
          label: `${hookFile} 실행 권한`,
          status: execOk ? 'ok' : 'error',
          detail: execOk ? undefined : `chmod +x "${hookPath}" 를 실행하세요`,
        });

        const registered = registeredHooks.some((h) => h.command.includes(hookFile));
        record({
          label: `${hookFile} settings.json 등록`,
          status: registered ? 'ok' : 'warn',
          detail: registered ? undefined : 'ai-harness init을 재실행하여 Hook을 등록하세요',
        });

        // 마지막 실행 결과 (로그에서)
        const logFile = join(logsDir, `${hookFile.replace('.sh', '')}.log`);
        if (existsSync(logFile)) {
          try {
            const logContent = await readFile(logFile, 'utf-8');
            const lines = logContent.trim().split('\n').filter(Boolean);
            const lastLine = lines[lines.length - 1] ?? '';
            const hasError = lastLine.toLowerCase().includes('error') || lastLine.toLowerCase().includes('fail');
            record({
              label: `${hookFile} 마지막 실행`,
              status: hasError ? 'warn' : 'ok',
              detail: hasError ? `마지막 로그: ${lastLine.slice(0, 80)}` : undefined,
            });
          } catch {}
        }
      }

      // ── 4. CLAUDE.md ───────────────────────────────────────────
      log.heading('CLAUDE.md');

      const claudeMdExists = existsSync(claudeMdPath);
      record({
        label: 'CLAUDE.md 존재',
        status: claudeMdExists ? 'ok' : 'warn',
        detail: claudeMdExists ? undefined : 'ai-harness init을 실행하여 CLAUDE.md를 생성하세요',
      });

      if (claudeMdExists) {
        try {
          const content = await readFile(claudeMdPath, 'utf-8');
          const hasSection = hasHarnessSection(content);
          record({
            label: 'harness:start ~ harness:end 구간 존재',
            status: hasSection ? 'ok' : 'warn',
            detail: hasSection ? undefined : 'ai-harness init을 재실행하여 harness 섹션을 주입하세요',
          });

          if (hasSection) {
            const startIdx = content.indexOf('<!-- harness:start -->');
            const endIdx = content.indexOf('<!-- harness:end -->');
            const sectionSize = endIdx - startIdx;
            record({
              label: `harness 구간 크기: ${sectionSize}자`,
              status: 'ok',
            });
          }
        } catch (err) {
          record({
            label: 'CLAUDE.md 읽기',
            status: 'error',
            detail: (err as Error).message,
          });
        }
      }

      // ── 5. 로그 ────────────────────────────────────────────────
      log.heading('로그');

      if (existsSync(logsDir)) {
        try {
          const logFiles = await readdir(logsDir);
          let totalErrors = 0;
          let totalBlocked = 0;

          for (const logFile of logFiles) {
            if (!logFile.endsWith('.log')) continue;
            const content = await readFile(join(logsDir, logFile), 'utf-8');
            const lines = content.split('\n');
            totalErrors += lines.filter((l) => l.toLowerCase().includes('error')).length;
            totalBlocked += lines.filter((l) => l.toLowerCase().includes('block') || l.toLowerCase().includes('차단')).length;
          }

          record({
            label: `최근 에러 건수: ${totalErrors}건`,
            status: totalErrors === 0 ? 'ok' : totalErrors < 10 ? 'warn' : 'error',
            detail: totalErrors >= 10 ? '로그를 확인하여 반복 오류를 해결하세요' : undefined,
          });

          record({
            label: `최근 차단 건수: ${totalBlocked}건`,
            status: 'ok',
          });

          const logDirSize = await dirSizeBytes(logsDir);
          record({
            label: `로그 디렉토리 크기: ${formatBytes(logDirSize)}`,
            status: logDirSize > 50 * 1024 * 1024 ? 'warn' : 'ok',
            detail: logDirSize > 50 * 1024 * 1024 ? '로그가 50MB를 초과했습니다. 정리를 고려하세요.' : undefined,
          });
        } catch (err) {
          record({
            label: '로그 디렉토리 읽기',
            status: 'warn',
            detail: (err as Error).message,
          });
        }
      } else {
        record({
          label: '로그 디렉토리',
          status: 'warn',
          detail: 'ai-harness init을 실행하여 로그 디렉토리를 생성하세요',
        });
      }

      // ── 6. 권장 사항 ───────────────────────────────────────────
      if (recommendations.length > 0) {
        log.heading('권장 사항');
        for (let i = 0; i < recommendations.length; i++) {
          console.log(`  ${chalk.yellow(`${i + 1}.`)} ${recommendations[i]}`);
        }
      }

      // ── 종합 점수 ──────────────────────────────────────────────
      console.log('');
      const score = `${passedChecks}/${totalChecks}`;
      const scoreColor = passedChecks === totalChecks
        ? chalk.green
        : passedChecks >= totalChecks * 0.8
          ? chalk.yellow
          : chalk.red;

      console.log(scoreColor(`  진단 점수: ${score}`));
      console.log('');

      if (passedChecks === totalChecks) {
        log.success('모든 진단을 통과했습니다.');
      } else if (passedChecks >= totalChecks * 0.8) {
        log.warn(`일부 항목을 확인하세요. (${totalChecks - passedChecks}개 미통과)`);
      } else {
        log.error(`여러 항목에 문제가 있습니다. 위 권장 사항을 따르세요. (${totalChecks - passedChecks}개 미통과)`);
        process.exit(1);
      }
    });
}
