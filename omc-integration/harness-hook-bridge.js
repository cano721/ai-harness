#!/usr/bin/env node
// harness-hook-bridge.js
// 하네스 ↔ OMC Hook 체이닝 브릿지
// 사용법: node harness-hook-bridge.js <event> <tool_name> <tool_input>
// event: PreToolUse | PostToolUse

import { execFileSync } from 'child_process';
import { existsSync, readdirSync, readFileSync } from 'fs';
import { join, resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const [event, toolName, toolInput] = process.argv.slice(2);

if (!event || !toolName) {
  console.error('[bridge] Usage: node harness-hook-bridge.js <event> <tool_name> [tool_input]');
  process.exit(1);
}

if (event !== 'PreToolUse' && event !== 'PostToolUse') {
  console.error(`[bridge] Unknown event: ${event}. Must be PreToolUse or PostToolUse`);
  process.exit(1);
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = resolve(__dirname, '..');
const PROJECT_ROOT = resolve(process.cwd());

// 글로벌 하네스 hooks (플러그인 내장)
const GLOBAL_HOOKS_DIR = join(PLUGIN_ROOT, 'hooks');
// 프로젝트 로컬 하네스 hooks
const LOCAL_HARNESS_DIR = join(PROJECT_ROOT, '.ai-harness');
// 홈 글로벌 하네스
const HOME_HARNESS_DIR = join(process.env.HOME || '', '.ai-harness');

function loadTeamNames(harnessDir) {
  const configPath = join(harnessDir, 'config.yaml');
  if (!existsSync(configPath)) return [];

  const content = readFileSync(configPath, 'utf8');
  const teams = [];
  const lines = content.split('\n');
  let inTeams = false;
  for (const line of lines) {
    if (/^teams:/.test(line)) { inTeams = true; continue; }
    if (inTeams && /^\S/.test(line)) break;
    if (inTeams) {
      const match = line.match(/^\s+-\s*(.+)/);
      if (match) teams.push(match[1].trim());
    }
  }
  return teams;
}

function collectShellScripts(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter(f => f.endsWith('.sh') && !f.endsWith('.test.yaml'))
    .sort()
    .map(f => join(dir, f));
}

function collectGlobalHooks(eventType) {
  // 글로벌 hooks에서 이벤트 타입에 맞는 것만 필터
  const allScripts = collectShellScripts(GLOBAL_HOOKS_DIR);
  if (eventType === 'PreToolUse') {
    return allScripts.filter(f => !f.includes('audit-logger') && !f.includes('coverage-check'));
  }
  // PostToolUse: audit-logger, coverage-check
  return allScripts.filter(f => f.includes('audit-logger') || f.includes('coverage-check'));
}

function collectTeamHooks(harnessDir, teams, eventType) {
  const hooks = [];
  for (const team of teams) {
    const teamHooksDir = join(harnessDir, 'teams', team, 'hooks');
    const scripts = collectShellScripts(teamHooksDir);
    if (eventType === 'PreToolUse') {
      hooks.push(...scripts.filter(f => !f.includes('coverage-check')));
    } else {
      hooks.push(...scripts.filter(f => f.includes('coverage-check')));
    }
  }
  return hooks;
}

function runHook(hookPath) {
  try {
    execFileSync('bash', [hookPath, toolName, toolInput || ''], {
      env: {
        ...process.env,
        HARNESS_EVENT: event,
        HARNESS_TOOL_NAME: toolName,
        HARNESS_TOOL_INPUT: toolInput || '',
        HARNESS_PROJECT_ROOT: PROJECT_ROOT,
        HARNESS_LOCAL_DIR: LOCAL_HARNESS_DIR,
      },
      stdio: 'inherit',
      timeout: 10000,
    });
    return 0;
  } catch (err) {
    const code = err.status ?? 1;
    if (code === 2) {
      console.error(`[bridge] Hook BLOCKED: ${hookPath}`);
    }
    return code;
  }
}

function runSequence(hooks) {
  for (const hook of hooks) {
    const code = runHook(hook);
    if (code === 2) {
      process.exit(2);
    }
  }
}

// 로컬 또는 홈 하네스에서 팀 로드
const localTeams = loadTeamNames(LOCAL_HARNESS_DIR);
const homeTeams = loadTeamNames(HOME_HARNESS_DIR);
const teams = localTeams.length > 0 ? localTeams : homeTeams;
const harnessDir = localTeams.length > 0 ? LOCAL_HARNESS_DIR : HOME_HARNESS_DIR;

const globalHooks = collectGlobalHooks(event);
const teamHooks = collectTeamHooks(harnessDir, teams, event);

if (event === 'PreToolUse') {
  // Pre: global → team
  runSequence(globalHooks);
  runSequence(teamHooks);
} else {
  // Post: team → global
  runSequence(teamHooks);
  runSequence(globalHooks);
}
