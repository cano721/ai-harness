#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

const MANAGED_BY = 'ai-harness';

function loadSettings(settingsPath) {
  if (!fs.existsSync(settingsPath)) {
    return {};
  }
  const content = fs.readFileSync(settingsPath, 'utf-8');
  return JSON.parse(content);
}

function saveSettings(settingsPath, settings) {
  const dir = path.dirname(settingsPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
}

// Claude Code Hook 포맷: { hooks: { "PreToolUse": [...], "PostToolUse": [...] } }
function ensureHooksStructure(settings) {
  if (!settings.hooks || Array.isArray(settings.hooks)) {
    settings.hooks = {};
  }
  return settings;
}

function ensureEventArray(settings, event) {
  ensureHooksStructure(settings);
  if (!Array.isArray(settings.hooks[event])) {
    settings.hooks[event] = [];
  }
  return settings;
}

function register(settingsPath, event, matcher, command) {
  const settings = loadSettings(settingsPath);
  ensureEventArray(settings, event);

  const hook = {
    matcher,
    command,
    _managed_by: MANAGED_BY,
  };

  const isDuplicate = settings.hooks[event].some(
    h => h.matcher === matcher && h.command === command
  );
  if (isDuplicate) {
    console.log(JSON.stringify({ ok: true, registered: null, skipped: 'duplicate matcher+command' }));
    return;
  }

  settings.hooks[event].push(hook);
  saveSettings(settingsPath, settings);
  console.log(JSON.stringify({ ok: true, registered: { event, ...hook } }));
}

function unregister(settingsPath) {
  const settings = loadSettings(settingsPath);
  ensureHooksStructure(settings);

  let removed = 0;
  for (const event of Object.keys(settings.hooks)) {
    if (!Array.isArray(settings.hooks[event])) continue;
    const before = settings.hooks[event].length;
    settings.hooks[event] = settings.hooks[event].filter(h => h._managed_by !== MANAGED_BY);
    removed += before - settings.hooks[event].length;
    if (settings.hooks[event].length === 0) {
      delete settings.hooks[event];
    }
  }

  saveSettings(settingsPath, settings);
  console.log(JSON.stringify({ ok: true, removed }));
}

function unregisterTeam(settingsPath, team) {
  const settings = loadSettings(settingsPath);
  ensureHooksStructure(settings);

  let removed = 0;
  for (const event of Object.keys(settings.hooks)) {
    if (!Array.isArray(settings.hooks[event])) continue;
    const before = settings.hooks[event].length;
    settings.hooks[event] = settings.hooks[event].filter(
      h => !(h._managed_by === MANAGED_BY && h._team === team)
    );
    removed += before - settings.hooks[event].length;
    if (settings.hooks[event].length === 0) {
      delete settings.hooks[event];
    }
  }

  saveSettings(settingsPath, settings);
  console.log(JSON.stringify({ ok: true, removed, team }));
}

function list(settingsPath) {
  const settings = loadSettings(settingsPath);
  ensureHooksStructure(settings);

  const hooks = [];
  for (const event of Object.keys(settings.hooks)) {
    if (!Array.isArray(settings.hooks[event])) continue;
    for (const h of settings.hooks[event]) {
      if (h._managed_by === MANAGED_BY) {
        hooks.push({ event, ...h });
      }
    }
  }
  console.log(JSON.stringify(hooks));
}

const [,, cmd, settingsPath, ...rest] = process.argv;

if (!cmd || !settingsPath) {
  console.error('사용법:');
  console.error('  node scripts/register-hooks.mjs register <settingsPath> <event> <matcher> <command>');
  console.error('  node scripts/register-hooks.mjs unregister <settingsPath>');
  console.error('  node scripts/register-hooks.mjs unregister-team <settingsPath> <team>');
  console.error('  node scripts/register-hooks.mjs list <settingsPath>');
  process.exit(1);
}

try {
  if (cmd === 'register') {
    const [event, matcher, command] = rest;
    if (!event || !matcher || !command) {
      console.error('register에는 event, matcher, command가 필요합니다.');
      process.exit(1);
    }
    register(settingsPath, event, matcher, command);
  } else if (cmd === 'unregister') {
    unregister(settingsPath);
  } else if (cmd === 'unregister-team') {
    const [team] = rest;
    if (!team) {
      console.error('unregister-team에는 team이 필요합니다.');
      process.exit(1);
    }
    unregisterTeam(settingsPath, team);
  } else if (cmd === 'list') {
    list(settingsPath);
  } else {
    console.error(`알 수 없는 명령: ${cmd}`);
    process.exit(1);
  }
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
