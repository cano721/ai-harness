import { Command } from 'commander';
import { existsSync } from 'fs';
import { readFile, writeFile, copyFile, mkdir, chmod, readdir } from 'fs/promises';
import { join, resolve } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { homedir } from 'os';
import { createInterface } from 'readline';
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
  global?: boolean;
  local?: boolean;
  team?: string[];
  preset?: string;
  noOmc?: boolean;
  dryRun?: boolean;
  nonInteractive?: boolean;
}

type Scope = 'global' | 'local';

function askQuestion(question: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function chooseScope(): Promise<Scope> {
  console.log('');
  log.heading('설치 범위 선택');
  console.log('');
  console.log('  [1] 글로벌 (Global)');
  console.log('      위치: ~/.ai-harness/, ~/.claude/');
  console.log('      범위: 모든 프로젝트에 보안 Hook 적용');
  console.log('      용도: 위험 명령 차단, 시크릿 보호, 감사 로깅');
  console.log('      특징: 어떤 프로젝트에서든 기본 안전망으로 동작');
  console.log('');
  console.log('  [2] 프로젝트 로컬 (Local)');
  console.log('      위치: ./.ai-harness/, ./.claude/');
  console.log('      범위: 현재 프로젝트에만 적용');
  console.log('      용도: 팀별 컨벤션, 팀별 Hook, Skill 설치');
  console.log('      특징: 프로젝트마다 다른 팀/규칙 적용 가능');
  console.log('');
  console.log('  [3] 둘 다 (Global + Local)');
  console.log('      글로벌로 기본 보안 + 이 프로젝트에 팀별 규칙 추가');
  console.log('');

  const answer = await askQuestion('  선택 (1/2/3, 기본: 2): ');

  if (answer === '1') return 'global';
  if (answer === '3') return 'both' as Scope;
  return 'local';
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
  return resolve(__dirname, '..', '..');
}

async function installHarness(
  scope: Scope,
  targetDir: string,
  claudeMdPath: string,
  settingsPath: string,
  teams: string[],
  packageRoot: string,
  dryRun: boolean,
): Promise<void> {
  const scopeLabel = scope === 'global' ? '글로벌' : '프로젝트 로컬';
  const harnessDir = join(targetDir, '.ai-harness');
  const hooksDestDir = join(harnessDir, 'hooks');
  const logsDir = join(harnessDir, 'logs');
  const hooksSourceDir = join(packageRoot, 'hooks');
  const claudeMdTemplatePath = join(packageRoot, 'templates', 'global', 'CLAUDE.md');

  log.heading(`${scopeLabel} 설치`);
  log.info(`설정 위치: ${harnessDir}`);
  log.info(`Hook 등록: ${settingsPath}`);
  log.info(`CLAUDE.md: ${claudeMdPath}`);

  if (dryRun) {
    log.warn('--dry-run 모드: 파일이 변경되지 않습니다.');
    return;
  }

  // 1. 디렉토리 생성
  await mkdir(harnessDir, { recursive: true });
  await mkdir(hooksDestDir, { recursive: true });
  await mkdir(logsDir, { recursive: true });

  // 2. config.yaml 생성
  const configPath = join(harnessDir, 'config.yaml');
  const config = {
    ...DEFAULT_CONFIG,
    scope,
    teams: scope === 'global' ? [] : teams,
  };
  await writeFile(configPath, stringify(config), 'utf-8');
  log.success('config.yaml 생성');

  // 3. Hook 스크립트 복사
  const hookFiles = ['block-dangerous.sh', 'secret-scanner.sh', 'audit-logger.sh'];
  for (const hookFile of hookFiles) {
    const src = join(hooksSourceDir, hookFile);
    const dest = join(hooksDestDir, hookFile);
    if (existsSync(src)) {
      await copyFile(src, dest);
      await chmod(dest, 0o755);
    }
  }
  log.success(`Hook ${hookFiles.length}개 복사`);

  // 4. CLAUDE.md 주입
  if (existsSync(claudeMdTemplatePath)) {
    const templateContent = await readFile(claudeMdTemplatePath, 'utf-8');
    await inject(claudeMdPath, templateContent);
    log.success('CLAUDE.md harness 섹션 주입');
  }

  // 5. Hook 등록
  const hookRegistrations = [
    { event: 'PreToolUse', matcher: '.*', command: join(hooksDestDir, 'block-dangerous.sh') },
    { event: 'PreToolUse', matcher: '.*', command: join(hooksDestDir, 'secret-scanner.sh') },
    { event: 'PostToolUse', matcher: '.*', command: join(hooksDestDir, 'audit-logger.sh') },
  ];

  // 6. 팀별 리소스 복사 (로컬만)
  if (scope === 'local' && teams.length > 0) {
    const teamsSourceDir = join(packageRoot, 'teams');
    if (existsSync(teamsSourceDir)) {
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
          const teamContent = await readFile(teamClaudeMd, 'utf-8');
          await inject(claudeMdPath, teamContent);
          log.success(`[${team}] CLAUDE.md`);
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
            const testYaml = hf.replace('.sh', '.test.yaml');
            if (existsSync(join(teamHooksSrc, testYaml))) {
              await copyFile(join(teamHooksSrc, testYaml), join(teamHooksDest, testYaml));
            }
            const isPostHook = hf.includes('coverage') || hf.includes('audit');
            hookRegistrations.push({
              event: isPostHook ? 'PostToolUse' : 'PreToolUse',
              matcher: '.*',
              command: join(teamHooksDest, hf),
            });
          }
          log.success(`[${team}] Hook ${teamHookFiles.length}개`);
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
          log.success(`[${team}] Skill ${skillFiles.length}개`);
        }
      }
    }
  }

  // Hook 등록
  await registerHooks(settingsPath, hookRegistrations);
  log.success(`Hook ${hookRegistrations.length}개 등록`);
}

export function registerInit(program: Command): void {
  program
    .command('init')
    .description('AI Harness를 초기화합니다')
    .option('--global', '글로벌 설치 (모든 프로젝트에 적용)')
    .option('--local', '프로젝트 로컬 설치 (현재 프로젝트만)')
    .option('--team <teams...>', '팀 목록 지정 (예: --team frontend backend)')
    .option('--preset <preset>', `프리셋 사용 (${Object.keys(PRESETS).join(', ')})`)
    .option('--no-omc', 'OMC 통합 없이 초기화')
    .option('--dry-run', '파일 변경 없이 계획만 출력')
    .option('--non-interactive', '대화형 프롬프트 없이 실행')
    .action(async (options: InitOptions) => {
      const cwd = process.cwd();
      const home = homedir();
      const dryRun = !!options.dryRun;
      const packageRoot = getPackageRoot();

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

      // 범위 결정
      let scope: Scope | 'both';
      if (options.global) {
        scope = 'global';
      } else if (options.local) {
        scope = 'local';
      } else if (options.nonInteractive) {
        scope = 'local';
      } else {
        scope = await chooseScope();
      }

      try {
        if (scope === 'global' || scope === 'both') {
          await installHarness(
            'global',
            home,
            join(home, '.claude', 'CLAUDE.md'),
            join(home, '.claude', 'settings.json'),
            teams,
            packageRoot,
            dryRun,
          );
        }

        if (scope === 'local' || scope === 'both') {
          if (teams.length > 0) {
            log.info(`설정할 팀: ${teams.join(', ')}`);
          }
          await installHarness(
            'local',
            cwd,
            join(cwd, 'CLAUDE.md'),
            join(cwd, '.claude', 'settings.json'),
            teams,
            packageRoot,
            dryRun,
          );
        }

        log.heading('초기화 완료');
        if (scope === 'global') {
          log.success('글로벌 설치 완료. 모든 프로젝트에서 보안 Hook이 동작합니다.');
        } else if (scope === 'local') {
          log.success(`프로젝트 로컬 설치 완료. (팀: ${teams.length > 0 ? teams.join(', ') : '없음'})`);
        } else {
          log.success('글로벌 + 로컬 설치 완료.');
          log.info('글로벌: 모든 프로젝트에 보안 Hook 적용');
          log.info(`로컬: 이 프로젝트에 팀별 규칙 적용 (팀: ${teams.length > 0 ? teams.join(', ') : '없음'})`);
        }
      } catch (err) {
        log.error(`초기화 실패: ${(err as Error).message}`);
        process.exit(1);
      }
    });
}
