import { Command } from 'commander';
import { existsSync } from 'fs';
import { readFile, writeFile, copyFile, mkdir, chmod, readdir } from 'fs/promises';
import { join, resolve } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { log } from '../utils/logger.js';
import { inject } from '../engine/claudemd-injector.js';
import { registerHooks } from '../engine/settings-manager.js';
import { stringify } from 'yaml';
import { DEFAULT_CONFIG } from '../types/index.js';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

const PRESETS: Record<string, string[]> = {
  fullstack: ['frontend', 'backend'],
  product: ['planning', 'design', 'frontend', 'backend'],
  all: ['planning', 'design', 'frontend', 'backend', 'qa', 'devops'],
};

interface InitOptions {
  team?: string[];
  preset?: string;
  noOmc?: boolean;
  dryRun?: boolean;
  nonInteractive?: boolean;
}

function detectEnvironment(): { nodeOk: boolean; gitOk: boolean; claudeOk: boolean } {
  const nodeVersion = process.version.replace('v', '').split('.').map(Number);
  const nodeOk = nodeVersion[0] >= 18;

  let gitOk = false;
  try {
    execSync('git --version', { stdio: 'ignore' });
    gitOk = true;
  } catch {}

  let claudeOk = false;
  try {
    execSync('which claude', { stdio: 'ignore' });
    claudeOk = true;
  } catch {
    try {
      execSync('command -v claude', { stdio: 'ignore', shell: '/bin/sh' });
      claudeOk = true;
    } catch {}
  }

  return { nodeOk, gitOk, claudeOk };
}

function detectStack(cwd: string): string[] {
  const stacks: string[] = [];
  if (existsSync(join(cwd, 'package.json'))) stacks.push('Node.js');
  if (existsSync(join(cwd, 'tsconfig.json'))) stacks.push('TypeScript');
  if (existsSync(join(cwd, 'build.gradle')) || existsSync(join(cwd, 'pom.xml'))) stacks.push('Java');
  return stacks;
}

function resolveTeams(options: InitOptions): string[] {
  if (options.preset && PRESETS[options.preset]) {
    return PRESETS[options.preset];
  }
  if (options.team && options.team.length > 0) {
    return options.team;
  }
  return DEFAULT_CONFIG.teams;
}

function getPackageRoot(): string {
  // dist/cli 또는 src/cli 위치에서 package root를 찾는다
  return resolve(__dirname, '..', '..');
}

export function registerInit(program: Command): void {
  program
    .command('init')
    .description('현재 디렉토리에 AI Harness를 초기화합니다')
    .option('--team <teams...>', '팀 목록 지정 (예: --team frontend backend)')
    .option('--preset <preset>', `프리셋 사용 (${Object.keys(PRESETS).join(', ')})`)
    .option('--no-omc', 'OMC 통합 없이 초기화')
    .option('--dry-run', '파일 변경 없이 계획만 출력')
    .option('--non-interactive', '대화형 프롬프트 없이 실행')
    .action(async (options: InitOptions) => {
      const cwd = process.cwd();
      const dryRun = !!options.dryRun;

      log.heading('AI Harness 초기화');

      // 환경 감지
      const env = detectEnvironment();
      log.info(`Node.js ${process.version}: ${env.nodeOk ? '✔' : '❌'}`);
      log.info(`Git: ${env.gitOk ? '✔' : '❌'}`);
      log.info(`Claude Code: ${env.claudeOk ? '✔' : '⚠ (선택사항)'}`);

      if (!env.nodeOk) {
        log.error('Node.js 18 이상이 필요합니다.');
        process.exit(1);
      }

      // 스택 감지
      const stacks = detectStack(cwd);
      if (stacks.length > 0) {
        log.info(`감지된 스택: ${stacks.join(', ')}`);
      }

      // 팀 결정
      const teams = resolveTeams(options);
      log.info(`설정할 팀: ${teams.length > 0 ? teams.join(', ') : '(없음)'}`);

      const harnessDir = join(cwd, '.ai-harness');
      const configPath = join(harnessDir, 'config.yaml');
      const hooksDestDir = join(harnessDir, 'hooks');
      const logsDir = join(harnessDir, 'logs');
      const claudeMdPath = join(cwd, 'CLAUDE.md');
      const settingsPath = join(cwd, '.claude', 'settings.json');

      const packageRoot = getPackageRoot();
      const hooksSourceDir = join(packageRoot, 'hooks');
      const claudeMdTemplatePath = join(packageRoot, 'templates', 'global', 'CLAUDE.md');

      log.heading('실행 계획');
      log.info(`1. ${configPath} 생성`);
      log.info(`2. ${hooksDestDir}/ 에 Hook 스크립트 복사`);
      log.info(`3. ${claudeMdPath} 에 harness 섹션 주입`);
      log.info(`4. ${settingsPath} 에 Hook 등록`);

      if (dryRun) {
        log.warn('--dry-run 모드: 파일이 변경되지 않습니다.');
        return;
      }

      try {
        // 1. .ai-harness 디렉토리 생성
        await mkdir(harnessDir, { recursive: true });
        await mkdir(hooksDestDir, { recursive: true });
        await mkdir(logsDir, { recursive: true });

        // 2. config.yaml 생성
        const config = {
          ...DEFAULT_CONFIG,
          teams,
        };
        await writeFile(configPath, stringify(config), 'utf-8');
        log.success(`config.yaml 생성 완료: ${configPath}`);

        // 3. Hook 스크립트 복사
        const hookFiles = ['block-dangerous.sh', 'secret-scanner.sh', 'audit-logger.sh'];
        for (const hookFile of hookFiles) {
          const src = join(hooksSourceDir, hookFile);
          const dest = join(hooksDestDir, hookFile);
          if (existsSync(src)) {
            await copyFile(src, dest);
            await chmod(dest, 0o755);
            log.success(`Hook 복사: ${hookFile}`);
          } else {
            log.warn(`Hook 파일 없음 (건너뜀): ${src}`);
          }
        }

        // 4. CLAUDE.md 주입
        if (existsSync(claudeMdTemplatePath)) {
          const templateContent = await readFile(claudeMdTemplatePath, 'utf-8');
          await inject(claudeMdPath, templateContent);
          log.success(`CLAUDE.md harness 섹션 주입 완료`);
        } else {
          log.warn(`CLAUDE.md 템플릿 없음: ${claudeMdTemplatePath}`);
        }

        // 5. Hook 등록
        const hookRegistrations = [
          {
            event: 'PreToolUse',
            matcher: '.*',
            command: join(hooksDestDir, 'block-dangerous.sh'),
          },
          {
            event: 'PreToolUse',
            matcher: '.*',
            command: join(hooksDestDir, 'secret-scanner.sh'),
          },
          {
            event: 'PostToolUse',
            matcher: '.*',
            command: join(hooksDestDir, 'audit-logger.sh'),
          },
        ];

        // 6. 팀별 리소스 복사 (CLAUDE.md, hooks, skills)
        const teamsSourceDir = join(packageRoot, 'teams');
        if (teams.length > 0 && existsSync(teamsSourceDir)) {
          log.heading('팀별 리소스 설치');
          for (const team of teams) {
            const teamSrc = join(teamsSourceDir, team);
            if (!existsSync(teamSrc)) {
              log.warn(`팀 리소스 없음 (건너뜀): ${team}`);
              continue;
            }

            const teamDest = join(harnessDir, 'teams', team);
            await mkdir(teamDest, { recursive: true });

            // 팀 CLAUDE.md 복사
            const teamClaudeMd = join(teamSrc, 'CLAUDE.md');
            if (existsSync(teamClaudeMd)) {
              await copyFile(teamClaudeMd, join(teamDest, 'CLAUDE.md'));
              log.success(`[${team}] CLAUDE.md 복사`);

              // 팀 CLAUDE.md 내용도 프로젝트 CLAUDE.md에 주입
              const teamContent = await readFile(teamClaudeMd, 'utf-8');
              await inject(claudeMdPath, teamContent);
            }

            // 팀 hooks 복사
            const teamHooksSrc = join(teamSrc, 'hooks');
            if (existsSync(teamHooksSrc)) {
              const teamHooksDest = join(teamDest, 'hooks');
              await mkdir(teamHooksDest, { recursive: true });
              const teamHookFiles = (await readdir(teamHooksSrc)).filter(f => f.endsWith('.sh'));
              for (const hf of teamHookFiles) {
                await copyFile(join(teamHooksSrc, hf), join(teamHooksDest, hf));
                await chmod(join(teamHooksDest, hf), 0o755);
                // 테스트 YAML도 복사
                const testYaml = hf.replace('.sh', '.test.yaml');
                if (existsSync(join(teamHooksSrc, testYaml))) {
                  await copyFile(join(teamHooksSrc, testYaml), join(teamHooksDest, testYaml));
                }
                // 팀 Hook도 settings.json에 등록
                const isPostHook = hf.includes('coverage') || hf.includes('audit');
                hookRegistrations.push({
                  event: isPostHook ? 'PostToolUse' : 'PreToolUse',
                  matcher: '.*',
                  command: join(teamHooksDest, hf),
                });
              }
              log.success(`[${team}] Hook ${teamHookFiles.length}개 복사`);
            }

            // 팀 skills 복사
            const teamSkillsSrc = join(teamSrc, 'skills');
            if (existsSync(teamSkillsSrc)) {
              const teamSkillsDest = join(teamDest, 'skills');
              await mkdir(teamSkillsDest, { recursive: true });
              const skillFiles = await readdir(teamSkillsSrc);
              for (const sf of skillFiles) {
                await copyFile(join(teamSkillsSrc, sf), join(teamSkillsDest, sf));
              }
              log.success(`[${team}] Skill ${skillFiles.length}개 복사`);
            }
          }
        }

        // Hook 등록 (global + team)
        await registerHooks(settingsPath, hookRegistrations);
        log.success(`Hook ${hookRegistrations.length}개 등록 완료: ${settingsPath}`);

        log.heading('초기화 완료');
        log.success(`AI Harness가 성공적으로 초기화되었습니다. (팀: ${teams.length > 0 ? teams.join(', ') : '없음'})`);
      } catch (err) {
        log.error(`초기화 실패: ${(err as Error).message}`);
        process.exit(1);
      }
    });
}
