import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { join } from 'path';
import { mkdtemp, rm, readFile, writeFile } from 'fs/promises';
import { tmpdir } from 'os';
import { registerHooks, unregisterHooks, getRegisteredHooks } from '../../src/engine/settings-manager.js';

describe('settings-manager', () => {
  let tmpDir: string;
  let settingsPath: string;

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), 'harness-test-'));
    settingsPath = join(tmpDir, '.claude', 'settings.json');
  });

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  it('빈 상태에서 Hook을 등록한다', async () => {
    await registerHooks(settingsPath, [
      { event: 'PreToolUse', matcher: '*', command: '/path/to/hook.sh' },
    ]);

    const raw = JSON.parse(await readFile(settingsPath, 'utf-8'));
    expect(raw.hooks.PreToolUse).toHaveLength(1);
    expect(raw.hooks.PreToolUse[0]._managed_by).toBe('ai-harness');
  });

  it('기존 Hook을 보존하며 추가한다', async () => {
    const existing = {
      hooks: {
        PreToolUse: [{ matcher: 'Write', command: 'npm run lint' }],
      },
    };
    const { mkdir } = await import('fs/promises');
    const { dirname } = await import('path');
    await mkdir(dirname(settingsPath), { recursive: true });
    await writeFile(settingsPath, JSON.stringify(existing));

    await registerHooks(settingsPath, [
      { event: 'PreToolUse', matcher: '*', command: '/path/to/hook.sh' },
    ]);

    const raw = JSON.parse(await readFile(settingsPath, 'utf-8'));
    expect(raw.hooks.PreToolUse).toHaveLength(2);
    expect(raw.hooks.PreToolUse[0].command).toBe('npm run lint'); // 기존 보존
  });

  it('중복 등록을 방지한다', async () => {
    await registerHooks(settingsPath, [
      { event: 'PreToolUse', matcher: '*', command: '/path/to/hook.sh' },
    ]);
    await registerHooks(settingsPath, [
      { event: 'PreToolUse', matcher: '*', command: '/path/to/hook.sh' },
    ]);

    const raw = JSON.parse(await readFile(settingsPath, 'utf-8'));
    const managed = raw.hooks.PreToolUse.filter((h: any) => h._managed_by === 'ai-harness');
    expect(managed).toHaveLength(1);
  });

  it('하네스 Hook만 제거한다', async () => {
    const existing = {
      hooks: {
        PreToolUse: [
          { matcher: 'Write', command: 'npm run lint' },
          { matcher: '*', command: '/path/to/hook.sh', _managed_by: 'ai-harness' },
        ],
      },
    };
    const { mkdir } = await import('fs/promises');
    const { dirname } = await import('path');
    await mkdir(dirname(settingsPath), { recursive: true });
    await writeFile(settingsPath, JSON.stringify(existing));

    await unregisterHooks(settingsPath);

    const raw = JSON.parse(await readFile(settingsPath, 'utf-8'));
    expect(raw.hooks.PreToolUse).toHaveLength(1);
    expect(raw.hooks.PreToolUse[0].command).toBe('npm run lint');
  });

  it('등록된 하네스 Hook을 조회한다', async () => {
    await registerHooks(settingsPath, [
      { event: 'PreToolUse', matcher: '*', command: '/path/to/hook.sh' },
      { event: 'PostToolUse', matcher: '*', command: '/path/to/audit.sh' },
    ]);

    const hooks = await getRegisteredHooks(settingsPath);
    expect(hooks).toHaveLength(2);
  });
});
