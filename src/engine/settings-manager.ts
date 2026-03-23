import { readFile, writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { dirname } from 'path';
import type { HookConfig } from '../types/index.js';

const MANAGED_BY = 'ai-harness';

interface SettingsJson {
  hooks?: {
    PreToolUse?: HookEntry[];
    PostToolUse?: HookEntry[];
    [key: string]: HookEntry[] | undefined;
  };
  [key: string]: unknown;
}

interface HookEntry {
  matcher: string;
  command: string;
  _managed_by?: string;
}

export async function registerHooks(
  settingsPath: string,
  hooks: { event: string; matcher: string; command: string }[],
): Promise<void> {
  const dir = dirname(settingsPath);
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true });
  }

  const settings = await loadSettings(settingsPath);
  if (!settings.hooks) settings.hooks = {};

  for (const hook of hooks) {
    if (!settings.hooks[hook.event]) {
      settings.hooks[hook.event] = [];
    }

    const existing = settings.hooks[hook.event]!;
    const alreadyRegistered = existing.some(
      (h) => h._managed_by === MANAGED_BY && h.command === hook.command,
    );

    if (!alreadyRegistered) {
      existing.push({
        matcher: hook.matcher,
        command: hook.command,
        _managed_by: MANAGED_BY,
      });
    }
  }

  await writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
}

export async function unregisterHooks(settingsPath: string): Promise<void> {
  if (!existsSync(settingsPath)) return;

  const settings = await loadSettings(settingsPath);
  if (!settings.hooks) return;

  for (const event of Object.keys(settings.hooks)) {
    const entries = settings.hooks[event];
    if (Array.isArray(entries)) {
      settings.hooks[event] = entries.filter((h) => h._managed_by !== MANAGED_BY);
      if (settings.hooks[event]!.length === 0) {
        delete settings.hooks[event];
      }
    }
  }

  if (Object.keys(settings.hooks).length === 0) {
    delete settings.hooks;
  }

  await writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
}

export async function getRegisteredHooks(settingsPath: string): Promise<HookConfig[]> {
  if (!existsSync(settingsPath)) return [];

  const settings = await loadSettings(settingsPath);
  const result: HookConfig[] = [];

  if (!settings.hooks) return result;

  for (const event of Object.keys(settings.hooks)) {
    const entries = settings.hooks[event];
    if (Array.isArray(entries)) {
      for (const entry of entries) {
        if (entry._managed_by === MANAGED_BY) {
          result.push({
            matcher: entry.matcher,
            command: entry.command,
            _managed_by: entry._managed_by,
          });
        }
      }
    }
  }

  return result;
}

async function loadSettings(path: string): Promise<SettingsJson> {
  if (!existsSync(path)) return {};
  const raw = await readFile(path, 'utf-8');
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}
