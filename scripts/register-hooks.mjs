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

function register(settingsPath, event, matcher, command) {
  const settings = loadSettings(settingsPath);
  if (!settings.hooks) {
    settings.hooks = [];
  }
  const hook = {
    event,
    matcher,
    command,
    _managed_by: MANAGED_BY,
  };
  const isDuplicate = settings.hooks.some(h => h.event === event && h.command === command);
  if (isDuplicate) {
    console.log(JSON.stringify({ ok: true, registered: null, skipped: 'duplicate event+command' }));
    return;
  }
  settings.hooks.push(hook);
  saveSettings(settingsPath, settings);
  console.log(JSON.stringify({ ok: true, registered: hook }));
}

function unregister(settingsPath) {
  const settings = loadSettings(settingsPath);
  if (!settings.hooks) {
    console.log(JSON.stringify({ ok: true, removed: 0 }));
    return;
  }
  const before = settings.hooks.length;
  settings.hooks = settings.hooks.filter(h => h._managed_by !== MANAGED_BY);
  const removed = before - settings.hooks.length;
  saveSettings(settingsPath, settings);
  console.log(JSON.stringify({ ok: true, removed }));
}

function list(settingsPath) {
  const settings = loadSettings(settingsPath);
  const hooks = (settings.hooks || []).filter(h => h._managed_by === MANAGED_BY);
  console.log(JSON.stringify(hooks));
}

const [,, cmd, settingsPath, ...rest] = process.argv;

if (!cmd || !settingsPath) {
  console.error('사용법:');
  console.error('  node scripts/register-hooks.mjs register <settingsPath> <event> <matcher> <command>');
  console.error('  node scripts/register-hooks.mjs unregister <settingsPath>');
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
