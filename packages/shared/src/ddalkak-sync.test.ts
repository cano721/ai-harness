import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import {
  ensureDdalkakDir,
  ddalkakDirExists,
  writeConfig,
  readConfig,
  writeConventions,
  readConventions,
  writeRelations,
  detectTechStack,
  isGitRepo,
  migrateFromAiHarness,
} from './ddalkak-sync.js';

const TEST_DIR = '/tmp/ddalkak-sync-test';

beforeEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

describe('ensureDdalkakDir', () => {
  it('creates .ddalkak/ with subdirectories', async () => {
    await ensureDdalkakDir(TEST_DIR);
    expect(existsSync(join(TEST_DIR, '.ddalkak'))).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'agents'))).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'skills'))).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'hooks'))).toBe(true);
  });
});

describe('ddalkakDirExists', () => {
  it('returns false when not exists', async () => {
    expect(await ddalkakDirExists(TEST_DIR)).toBe(false);
  });

  it('returns true after creation', async () => {
    await ensureDdalkakDir(TEST_DIR);
    expect(await ddalkakDirExists(TEST_DIR)).toBe(true);
  });
});

describe('config YAML', () => {
  it('writes and reads config', async () => {
    await ensureDdalkakDir(TEST_DIR);
    await writeConfig(TEST_DIR, {
      name: 'test-project',
      description: 'A test',
      techStack: ['Node.js', 'TypeScript'],
      guardrails: { max_files_changed: 20, max_execution_minutes: 30 },
    });

    const config = await readConfig(TEST_DIR);
    expect(config).not.toBeNull();
    expect(config!.name).toBe('test-project');
    expect(config!.description).toBe('A test');
    expect(config!.techStack).toContain('Node.js');
    expect(config!.guardrails.max_files_changed).toBe(20);
  });

  it('returns null for missing config', async () => {
    const config = await readConfig(TEST_DIR);
    expect(config).toBeNull();
  });
});

describe('conventions YAML', () => {
  it('writes and reads conventions', async () => {
    await ensureDdalkakDir(TEST_DIR);
    await writeConventions(TEST_DIR, [
      { category: 'code-style', rule: 'no-force-push', scope: 'global', enabled: true },
      { category: 'security', rule: 'no-hardcoded-secrets', scope: 'project', enabled: false },
    ]);

    const convs = await readConventions(TEST_DIR);
    expect(convs).toHaveLength(2);
    expect(convs[0].category).toBe('code-style');
    expect(convs[0].rule).toBe('no-force-push');
    expect(convs[0].enabled).toBe(true);
    expect(convs[1].enabled).toBe(false);
  });

  it('returns empty array for missing file', async () => {
    const convs = await readConventions(TEST_DIR);
    expect(convs).toHaveLength(0);
  });
});

describe('relations YAML', () => {
  it('writes relations file', async () => {
    await ensureDdalkakDir(TEST_DIR);
    await writeRelations(TEST_DIR, [
      { targetName: 'frontend', type: 'depends_on' },
    ]);
    const content = readFileSync(join(TEST_DIR, '.ddalkak', 'relations.yaml'), 'utf-8');
    expect(content).toContain('frontend');
    expect(content).toContain('depends_on');
  });
});

describe('detectTechStack', () => {
  it('detects package.json as Node.js', async () => {
    writeFileSync(join(TEST_DIR, 'package.json'), '{"dependencies":{}}');
    const stack = await detectTechStack(TEST_DIR);
    expect(stack).toContain('Node.js');
  });

  it('detects tsconfig.json as TypeScript', async () => {
    writeFileSync(join(TEST_DIR, 'tsconfig.json'), '{}');
    const stack = await detectTechStack(TEST_DIR);
    expect(stack).toContain('TypeScript');
  });

  it('detects React from package.json deps', async () => {
    writeFileSync(join(TEST_DIR, 'package.json'), '{"dependencies":{"react":"^19"}}');
    const stack = await detectTechStack(TEST_DIR);
    expect(stack).toContain('React');
    expect(stack).toContain('Node.js');
  });

  it('detects Dockerfile', async () => {
    writeFileSync(join(TEST_DIR, 'Dockerfile'), 'FROM node:20');
    const stack = await detectTechStack(TEST_DIR);
    expect(stack).toContain('Docker');
  });

  it('returns empty for empty directory', async () => {
    const stack = await detectTechStack(TEST_DIR);
    expect(stack).toHaveLength(0);
  });
});

describe('isGitRepo', () => {
  it('returns false for non-git dir', () => {
    expect(isGitRepo(TEST_DIR)).toBe(false);
  });

  it('returns true for git dir', () => {
    mkdirSync(join(TEST_DIR, '.git'), { recursive: true });
    expect(isGitRepo(TEST_DIR)).toBe(true);
  });
});

describe('migrateFromAiHarness', () => {
  it('returns not migrated when no .ai-harness/', async () => {
    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.migrated).toBe(false);
  });

  it('migrates config.yaml', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(oldDir, { recursive: true });
    writeFileSync(join(oldDir, 'config.yaml'), 'name: "old-project"\n');

    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.migrated).toBe(true);
    expect(result.details.some(d => d.message === 'Migrated config.yaml')).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'config.yaml'))).toBe(true);
  });

  it('migrates context-map.md', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(oldDir, { recursive: true });
    writeFileSync(join(oldDir, 'context-map.md'), '# Context Map');

    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.migrated).toBe(true);
    expect(result.details.some(d => d.message === 'Migrated context-map.md')).toBe(true);
  });

  it('preserves original .ai-harness/', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(oldDir, { recursive: true });
    writeFileSync(join(oldDir, 'config.yaml'), 'name: "old"');

    await migrateFromAiHarness(TEST_DIR);
    expect(existsSync(oldDir)).toBe(true);
  });

  it('migrates agents/ directory', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(join(oldDir, 'agents'), { recursive: true });
    writeFileSync(join(oldDir, 'agents', 'my-agent.md'), '# My Agent');

    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.migrated).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'agents', 'my-agent.md'))).toBe(true);
    expect(result.details.some(d => d.status === 'migrated' && d.message.includes('my-agent.md'))).toBe(true);
  });

  it('migrates skills/ directory', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(join(oldDir, 'skills'), { recursive: true });
    writeFileSync(join(oldDir, 'skills', 'my-skill.md'), '# My Skill');

    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.migrated).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'skills', 'my-skill.md'))).toBe(true);
  });

  it('migrates hooks/ directory', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(join(oldDir, 'hooks'), { recursive: true });
    writeFileSync(join(oldDir, 'hooks', 'pre-commit.sh'), '#!/bin/bash');

    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.migrated).toBe(true);
    expect(existsSync(join(TEST_DIR, '.ddalkak', 'hooks', 'pre-commit.sh'))).toBe(true);
    expect(result.details.some(d => d.status === 'migrated' && d.message.includes('pre-commit.sh'))).toBe(true);
  });

  it('skips existing files without --force', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(oldDir, { recursive: true });
    writeFileSync(join(oldDir, 'config.yaml'), 'name: "new"');

    // Create existing file
    mkdirSync(join(TEST_DIR, '.ddalkak'), { recursive: true });
    writeFileSync(join(TEST_DIR, '.ddalkak', 'config.yaml'), 'name: "existing"');

    const result = await migrateFromAiHarness(TEST_DIR);
    expect(result.details.some(d => d.status === 'skipped')).toBe(true);
    // Existing file should not be overwritten
    const content = readFileSync(join(TEST_DIR, '.ddalkak', 'config.yaml'), 'utf-8');
    expect(content).toContain('existing');
  });

  it('overwrites existing files with --force', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(oldDir, { recursive: true });
    writeFileSync(join(oldDir, 'config.yaml'), 'name: "new"');

    mkdirSync(join(TEST_DIR, '.ddalkak'), { recursive: true });
    writeFileSync(join(TEST_DIR, '.ddalkak', 'config.yaml'), 'name: "existing"');

    const result = await migrateFromAiHarness(TEST_DIR, { force: true });
    expect(result.details.some(d => d.status === 'migrated' && d.message.includes('config.yaml'))).toBe(true);
    const content = readFileSync(join(TEST_DIR, '.ddalkak', 'config.yaml'), 'utf-8');
    expect(content).toContain('new');
  });

  it('dry-run does not write any files', async () => {
    const oldDir = join(TEST_DIR, '.ai-harness');
    mkdirSync(join(oldDir, 'agents'), { recursive: true });
    writeFileSync(join(oldDir, 'config.yaml'), 'name: "test"');
    writeFileSync(join(oldDir, 'agents', 'agent.md'), '# Agent');

    const result = await migrateFromAiHarness(TEST_DIR, { dryRun: true });
    expect(result.migrated).toBe(true);
    expect(result.details.some(d => d.status === 'migrated')).toBe(true);
    // Nothing should be written
    expect(existsSync(join(TEST_DIR, '.ddalkak'))).toBe(false);
  });
});
