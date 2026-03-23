#!/usr/bin/env node
// harness-hook-bridge.js
// 하네스 ↔ OMC Hook 체이닝 브릿지
// 사용법: node harness-hook-bridge.js <event> <tool_name> <tool_input>
// event: PreToolUse | PostToolUse

import { execFileSync } from 'child_process';
import { existsSync, readdirSync, readFileSync } from 'fs';
import { join, resolve } from 'path';

const [event, toolName, toolInput] = process.argv.slice(2);

if (!event || !toolName) {
  console.error('[bridge] Usage: node harness-hook-bridge.js <event> <tool_name> [tool_input]');
  process.exit(1);
}

if (event !== 'PreToolUse' && event !== 'PostToolUse') {
  console.error(`[bridge] Unknown event: ${event}. Must be PreToolUse or PostToolUse`);
  process.exit(1);
}

const PROJECT_ROOT = resolve(process.cwd());
const HARNESS_HOOKS_DIR = join(PROJECT_ROOT, 'hooks');
const OMC_HOOKS_DIR = join(PROJECT_ROOT, '.claude', 'hooks');

function loadTeamNames() {
  const configPath = join(PROJECT_ROOT, '.ai-harness', 'config.yaml');
  if (!existsSync(configPath)) return [];

  const content = readFileSync(configPath, 'utf8');
  const teams = [];
  const teamMatch = content.match(/teams:\s*\n([\s\S]*?)(?=\n\S|\s*$)/);
  if (teamMatch) {
    const teamLines = teamMatch[1].split('\n');
    for (const line of teamLines) {
      const nameMatch = line.match(/^\s+-?\s*name:\s*(.+)/);
      if (nameMatch) teams.push(nameMatch[1].trim());
    }
  }
  return teams;
}

function collectHooks(dir, eventType) {
  if (!existsSync(dir)) return [];

  const subdir = join(dir, eventType);
  if (existsSync(subdir)) {
    return readdirSync(subdir)
      .filter(f => f.endsWith('.sh'))
      .sort()
      .map(f => join(subdir, f));
  }

  return readdirSync(dir)
    .filter(f => f.endsWith('.sh') && f.toLowerCase().includes(eventType.toLowerCase()))
    .sort()
    .map(f => join(dir, f));
}

function collectTeamHooks(teams, eventType) {
  const hooks = [];
  for (const team of teams) {
    const teamDir = join(PROJECT_ROOT, 'teams', team, 'hooks');
    hooks.push(...collectHooks(teamDir, eventType));
  }
  return hooks;
}

function collectOmcHooks(eventType) {
  return collectHooks(OMC_HOOKS_DIR, eventType);
}

function runHook(hookPath) {
  console.log(`[bridge] Running hook: ${hookPath}`);
  try {
    execFileSync('bash', [hookPath, toolName, toolInput || ''], {
      env: {
        ...process.env,
        HARNESS_EVENT: event,
        HARNESS_TOOL_NAME: toolName,
        HARNESS_TOOL_INPUT: toolInput || '',
      },
      stdio: 'inherit',
    });
    console.log(`[bridge] Hook passed: ${hookPath}`);
    return 0;
  } catch (err) {
    const code = err.status ?? 1;
    if (code === 2) {
      console.error(`[bridge] Hook BLOCKED (exit 2): ${hookPath}`);
    } else {
      console.error(`[bridge] Hook failed (exit ${code}): ${hookPath}`);
    }
    return code;
  }
}

function runSequence(hooks) {
  for (const hook of hooks) {
    const code = runHook(hook);
    if (code === 2) {
      console.error(`[bridge] Execution stopped — hook returned exit 2`);
      process.exit(2);
    }
  }
}

const teams = loadTeamNames();
const harnessGlobalHooks = collectHooks(HARNESS_HOOKS_DIR, event);
const teamHooks = collectTeamHooks(teams, event);
const omcHooks = collectOmcHooks(event);

console.log(`[bridge] Event: ${event}, Tool: ${toolName}`);
console.log(`[bridge] Harness global hooks: ${harnessGlobalHooks.length}`);
console.log(`[bridge] Team hooks: ${teamHooks.length}`);
console.log(`[bridge] OMC hooks: ${omcHooks.length}`);

if (event === 'PreToolUse') {
  // Pre: global → team → omc
  runSequence(harnessGlobalHooks);
  runSequence(teamHooks);
  runSequence(omcHooks);
} else {
  // Post: omc → team → global
  runSequence(omcHooks);
  runSequence(teamHooks);
  runSequence(harnessGlobalHooks);
}

console.log(`[bridge] All hooks completed for ${event}:${toolName}`);
