import { Command } from 'commander';
import { existsSync } from 'fs';
import { readFile, writeFile } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';
import { parse, stringify } from 'yaml';
import { log } from '../utils/logger.js';
import type { HarnessConfig } from '../types/index.js';

function getGlobalConfigPath(): string {
  return join(homedir(), '.ai-harness', 'config.yaml');
}

async function loadGlobalConfig(configPath: string): Promise<HarnessConfig | null> {
  if (!existsSync(configPath)) return null;
  const raw = await readFile(configPath, 'utf-8');
  return parse(raw) as HarnessConfig;
}

async function saveGlobalConfig(configPath: string, config: HarnessConfig): Promise<void> {
  await writeFile(configPath, stringify(config), 'utf-8');
}

export function registerExclude(program: Command): void {
  const cmd = program
    .command('exclude')
    .description('글로벌 하네스에서 제외할 프로젝트를 관리합니다');

  cmd
    .command('add <path>')
    .description('프로젝트 경로를 제외 목록에 추가')
    .action(async (projectPath: string) => {
      const configPath = getGlobalConfigPath();
      const config = await loadGlobalConfig(configPath);

      if (!config) {
        log.error('글로벌 설정이 없습니다. `ai-harness init --global`을 먼저 실행하세요.');
        process.exit(1);
      }

      if (!config.exclude_projects) {
        config.exclude_projects = [];
      }

      const resolved = projectPath.startsWith('/') ? projectPath : join(process.cwd(), projectPath);

      if (config.exclude_projects.includes(resolved)) {
        log.warn(`이미 제외 목록에 있습니다: ${resolved}`);
        return;
      }

      config.exclude_projects.push(resolved);
      await saveGlobalConfig(configPath, config);
      log.success(`제외 추가: ${resolved}`);
      log.info(`현재 제외 목록: ${config.exclude_projects.length}개`);
    });

  cmd
    .command('remove <path>')
    .description('프로젝트 경로를 제외 목록에서 제거')
    .action(async (projectPath: string) => {
      const configPath = getGlobalConfigPath();
      const config = await loadGlobalConfig(configPath);

      if (!config || !config.exclude_projects) {
        log.warn('제외 목록이 비어 있습니다.');
        return;
      }

      const resolved = projectPath.startsWith('/') ? projectPath : join(process.cwd(), projectPath);
      const idx = config.exclude_projects.indexOf(resolved);

      if (idx === -1) {
        log.warn(`제외 목록에 없습니다: ${resolved}`);
        return;
      }

      config.exclude_projects.splice(idx, 1);
      await saveGlobalConfig(configPath, config);
      log.success(`제외 제거: ${resolved}`);
    });

  cmd
    .command('list')
    .description('제외된 프로젝트 목록 표시')
    .action(async () => {
      const configPath = getGlobalConfigPath();
      const config = await loadGlobalConfig(configPath);

      if (!config || !config.exclude_projects || config.exclude_projects.length === 0) {
        log.info('제외된 프로젝트가 없습니다.');
        return;
      }

      log.heading('제외 프로젝트 목록');
      for (const p of config.exclude_projects) {
        console.log(`  • ${p}`);
      }
      log.info(`총 ${config.exclude_projects.length}개`);
    });
}
