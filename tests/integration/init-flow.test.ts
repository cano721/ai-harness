import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, rm, writeFile, mkdir, copyFile, chmod } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { existsSync, readFileSync } from 'fs';
import { stringify } from 'yaml';
import { loadConfig, loadLockPolicy } from '../../src/engine/config-loader.js';
import { validateConfig } from '../../src/engine/lock-enforcer.js';
import { inject, hasHarnessSection } from '../../src/engine/claudemd-injector.js';
import { registerHooks, getRegisteredHooks } from '../../src/engine/settings-manager.js';
import { DEFAULT_CONFIG } from '../../src/types/index.js';

const PROJECT_ROOT = join(import.meta.dirname, '..', '..');
const HOOKS_SOURCE = join(PROJECT_ROOT, 'hooks');

describe('init 흐름 통합 테스트', () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), 'ai-harness-test-'));
  });

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  describe('config.yaml 생성', () => {
    it('DEFAULT_CONFIG 기반으로 config.yaml이 올바르게 생성된다', async () => {
      const configPath = join(tmpDir, '.ai-harness', 'config.yaml');
      await mkdir(join(tmpDir, '.ai-harness'), { recursive: true });

      const yamlContent = stringify(DEFAULT_CONFIG);
      await writeFile(configPath, yamlContent, 'utf-8');

      expect(existsSync(configPath)).toBe(true);

      const loaded = await loadConfig(configPath);
      expect(loaded._schema_version).toBe(DEFAULT_CONFIG._schema_version);
      expect(loaded.teams).toEqual(DEFAULT_CONFIG.teams);
      expect(loaded.guardrails.max_files_changed).toBe(DEFAULT_CONFIG.guardrails.max_files_changed);
      expect(loaded.guardrails.max_cost_usd).toBe(DEFAULT_CONFIG.guardrails.max_cost_usd);
      expect(loaded.guardrails.max_execution_minutes).toBe(DEFAULT_CONFIG.guardrails.max_execution_minutes);
    });

    it('생성된 config.yaml의 내용이 YAML 형식으로 유효하다', async () => {
      const configPath = join(tmpDir, '.ai-harness', 'config.yaml');
      await mkdir(join(tmpDir, '.ai-harness'), { recursive: true });

      const yamlContent = stringify(DEFAULT_CONFIG);
      await writeFile(configPath, yamlContent, 'utf-8');

      const raw = readFileSync(configPath, 'utf-8');
      expect(raw).toContain('_schema_version');
      expect(raw).toContain('guardrails');
    });
  });

  describe('hooks 디렉토리 복사', () => {
    it('.sh 파일들이 대상 디렉토리로 복사된다', async () => {
      const targetHooksDir = join(tmpDir, '.ai-harness', 'hooks');
      await mkdir(targetHooksDir, { recursive: true });

      const shFiles = ['audit-logger.sh', 'block-dangerous.sh', 'secret-scanner.sh'];
      const copiedFiles: string[] = [];

      for (const file of shFiles) {
        const src = join(HOOKS_SOURCE, file);
        if (existsSync(src)) {
          const dest = join(targetHooksDir, file);
          await copyFile(src, dest);
          await chmod(dest, 0o755);
          copiedFiles.push(file);
        }
      }

      expect(copiedFiles.length).toBeGreaterThan(0);

      for (const file of copiedFiles) {
        const dest = join(targetHooksDir, file);
        expect(existsSync(dest)).toBe(true);
      }
    });

    it('복사된 .sh 파일은 실행 가능하다', async () => {
      const targetHooksDir = join(tmpDir, '.ai-harness', 'hooks');
      await mkdir(targetHooksDir, { recursive: true });

      const shFiles = ['audit-logger.sh', 'block-dangerous.sh', 'secret-scanner.sh'];

      for (const file of shFiles) {
        const src = join(HOOKS_SOURCE, file);
        if (existsSync(src)) {
          const dest = join(targetHooksDir, file);
          await copyFile(src, dest);
          await chmod(dest, 0o755);

          const { statSync } = await import('fs');
          const stat = statSync(dest);
          const isExecutable = (stat.mode & 0o111) !== 0;
          expect(isExecutable).toBe(true);
        }
      }
    });
  });

  describe('CLAUDE.md 주입', () => {
    it('CLAUDE.md가 없으면 harness 섹션을 포함하여 새로 생성된다', async () => {
      const claudeMdPath = join(tmpDir, 'CLAUDE.md');

      await inject(claudeMdPath, 'AI Harness가 활성화되었습니다.');

      expect(existsSync(claudeMdPath)).toBe(true);
      const content = readFileSync(claudeMdPath, 'utf-8');
      expect(hasHarnessSection(content)).toBe(true);
      expect(content).toContain('AI Harness가 활성화되었습니다.');
    });

    it('기존 CLAUDE.md에 harness 섹션이 추가된다', async () => {
      const claudeMdPath = join(tmpDir, 'CLAUDE.md');
      await writeFile(claudeMdPath, '# 기존 내용\n\n기존 프로젝트 가이드라인\n', 'utf-8');

      await inject(claudeMdPath, 'harness 주입 내용');

      const content = readFileSync(claudeMdPath, 'utf-8');
      expect(hasHarnessSection(content)).toBe(true);
      expect(content).toContain('기존 내용');
      expect(content).toContain('harness 주입 내용');
    });

    it('이미 harness 섹션이 있으면 내용을 교체한다', async () => {
      const claudeMdPath = join(tmpDir, 'CLAUDE.md');

      await inject(claudeMdPath, '초기 harness 내용');
      await inject(claudeMdPath, '업데이트된 harness 내용');

      const content = readFileSync(claudeMdPath, 'utf-8');
      expect(hasHarnessSection(content)).toBe(true);
      expect(content).toContain('업데이트된 harness 내용');
      expect(content).not.toContain('초기 harness 내용');
    });
  });

  describe('settings.json hook 등록', () => {
    it('registerHooks()로 hook이 settings.json에 등록된다', async () => {
      const settingsPath = join(tmpDir, '.claude', 'settings.json');

      await registerHooks(settingsPath, [
        { event: 'PreToolUse', matcher: '.*', command: '/path/to/audit-logger.sh' },
      ]);

      expect(existsSync(settingsPath)).toBe(true);
      const raw = readFileSync(settingsPath, 'utf-8');
      const settings = JSON.parse(raw);
      expect(settings.hooks).toBeDefined();
      expect(settings.hooks.PreToolUse).toBeDefined();
      expect(settings.hooks.PreToolUse.length).toBeGreaterThan(0);
    });

    it('getRegisteredHooks()로 등록된 hook 목록을 조회한다', async () => {
      const settingsPath = join(tmpDir, '.claude', 'settings.json');

      await registerHooks(settingsPath, [
        { event: 'PreToolUse', matcher: '.*', command: '/path/to/block-dangerous.sh' },
        { event: 'PostToolUse', matcher: '.*', command: '/path/to/audit-logger.sh' },
      ]);

      const registered = await getRegisteredHooks(settingsPath);
      expect(registered.length).toBe(2);
      expect(registered.some((h) => h.command === '/path/to/block-dangerous.sh')).toBe(true);
      expect(registered.some((h) => h.command === '/path/to/audit-logger.sh')).toBe(true);
    });

    it('동일한 hook을 중복 등록해도 한 번만 등록된다', async () => {
      const settingsPath = join(tmpDir, '.claude', 'settings.json');
      const hookDef = { event: 'PreToolUse', matcher: '.*', command: '/path/to/secret-scanner.sh' };

      await registerHooks(settingsPath, [hookDef]);
      await registerHooks(settingsPath, [hookDef]);

      const registered = await getRegisteredHooks(settingsPath);
      const matchingHooks = registered.filter((h) => h.command === hookDef.command);
      expect(matchingHooks.length).toBe(1);
    });
  });

  describe('doctor 검증 로직', () => {
    it('유효한 config와 lock-policy 조합은 위반이 없다', async () => {
      const configPath = join(tmpDir, '.ai-harness', 'config.yaml');
      await mkdir(join(tmpDir, '.ai-harness'), { recursive: true });
      await writeFile(configPath, stringify(DEFAULT_CONFIG), 'utf-8');

      const config = await loadConfig(configPath);
      const policy = await loadLockPolicy('/nonexistent/lock-policy.yaml');

      const violations = validateConfig(config, policy);
      expect(violations).toHaveLength(0);
    });

    it('locked hook을 비활성화하면 위반이 감지된다', async () => {
      const configPath = join(tmpDir, '.ai-harness', 'config.yaml');
      await mkdir(join(tmpDir, '.ai-harness'), { recursive: true });

      const invalidConfig = {
        ...DEFAULT_CONFIG,
        hooks: {
          'block-dangerous': { enabled: false },
        },
      };
      await writeFile(configPath, stringify(invalidConfig), 'utf-8');

      const config = await loadConfig(configPath);
      const policy = await loadLockPolicy('/nonexistent/lock-policy.yaml');

      const violations = validateConfig(config, policy);
      expect(violations.length).toBeGreaterThan(0);
      expect(violations.some((v) => v.key === 'hooks.block-dangerous')).toBe(true);
    });

    it('guardrails 범위 초과 시 위반이 감지된다', async () => {
      const configPath = join(tmpDir, '.ai-harness', 'config.yaml');
      await mkdir(join(tmpDir, '.ai-harness'), { recursive: true });

      const invalidConfig = {
        ...DEFAULT_CONFIG,
        guardrails: {
          ...DEFAULT_CONFIG.guardrails,
          max_cost_usd: 999.0,
        },
      };
      await writeFile(configPath, stringify(invalidConfig), 'utf-8');

      const config = await loadConfig(configPath);
      const policy = await loadLockPolicy('/nonexistent/lock-policy.yaml');

      const violations = validateConfig(config, policy);
      expect(violations.length).toBeGreaterThan(0);
      expect(violations.some((v) => v.key === 'guardrails.max_cost_usd')).toBe(true);
    });
  });
});
