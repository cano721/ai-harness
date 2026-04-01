import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import path from 'path';
import url from 'url';
import {
  buildInstallPlan,
  detectRuntime,
  isTextFile,
  parseArgs,
  resolveBundleConfig,
} from './install-planner-bundle.mjs';

function restoreEnv(envBackup) {
  for (const key of Object.keys(process.env)) {
    delete process.env[key];
  }
  Object.assign(process.env, envBackup);
}

const repoRoot = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const claudeBundleRoot = path.join(repoRoot, 'teams', 'planning', 'bundle-claude');
const codexBundleRoot = path.join(repoRoot, 'teams', 'planning', 'bundle-codex');

describe('parseArgs', () => {
  it('위치 인수를 _에 수집한다', () => {
    const result = parseArgs(['inspect']);
    assert.deepStrictEqual(result._, ['inspect']);
  });

  it('--key value 쌍을 파싱한다', () => {
    const result = parseArgs(['--runtime', 'codex', '--bundle-root', '/tmp']);
    assert.equal(result.runtime, 'codex');
    assert.equal(result['bundle-root'], '/tmp');
  });

  it('값 없는 플래그는 true로 설정한다', () => {
    const result = parseArgs(['install', '--dry-run']);
    assert.deepStrictEqual(result._, ['install']);
    assert.equal(result['dry-run'], true);
  });
});

describe('detectRuntime', () => {
  it('명시적 runtime을 그대로 반환한다', () => {
    const result = detectRuntime('claude', '/tmp');
    assert.equal(result.runtime, 'claude');
    assert.equal(result.detectionReason, 'explicit:claude');
  });

  it('명시적 codex를 그대로 반환한다', () => {
    const result = detectRuntime('codex', '/tmp');
    assert.equal(result.runtime, 'codex');
    assert.equal(result.detectionReason, 'explicit:codex');
  });

  it('Claude 전용 환경 변수가 있으면 Codex 관련 변수보다 우선한다', () => {
    const envBackup = { ...process.env };
    process.env.CLAUDECODE = '1';
    process.env.CODEX_THREAD_ID = 'thread_123';
    process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE = '1';
    process.env.CODEX_SHELL = '1';

    const result = detectRuntime(undefined, '/tmp');
    assert.equal(result.runtime, 'claude');
    assert.equal(result.detectionReason, 'env:claude');

    restoreEnv(envBackup);
  });

  it('CODEX_THREAD_ID가 있으면 codex를 반환한다', () => {
    const envBackup = { ...process.env };
    delete process.env.CLAUDECODE;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CLAUDE_PROJECT_DIR;
    process.env.CODEX_THREAD_ID = 'thread_123';
    delete process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
    process.env.CODEX_SHELL = '1';

    const result = detectRuntime(undefined, '/tmp');
    assert.equal(result.runtime, 'codex');
    assert.equal(result.detectionReason, 'env:codex-thread');

    restoreEnv(envBackup);
  });

  it('CODEX_SHELL만 있으면 codex-shell-fallback으로 감지한다', () => {
    const envBackup = { ...process.env };
    delete process.env.CLAUDECODE;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CLAUDE_PROJECT_DIR;
    delete process.env.CODEX_THREAD_ID;
    delete process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
    process.env.CODEX_SHELL = '1';

    const result = detectRuntime(undefined, '/tmp');
    assert.equal(result.runtime, 'codex');
    assert.equal(result.detectionReason, 'env:codex-shell-fallback');

    restoreEnv(envBackup);
  });

  it('CODEX_SHELL이 있어도 Claude 환경 변수가 우선한다', () => {
    const envBackup = { ...process.env };
    process.env.CLAUDECODE = '1';
    delete process.env.CODEX_THREAD_ID;
    delete process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
    process.env.CODEX_SHELL = '1';

    const result = detectRuntime(undefined, '/tmp');
    assert.equal(result.runtime, 'claude');
    assert.equal(result.detectionReason, 'env:claude');

    restoreEnv(envBackup);
  });

  it('CODEX_INTERNAL_ORIGINATOR_OVERRIDE가 있으면 보조 codex 신호로 사용한다', () => {
    const envBackup = { ...process.env };
    delete process.env.CLAUDECODE;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CLAUDE_PROJECT_DIR;
    delete process.env.CODEX_THREAD_ID;
    process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE = '1';
    delete process.env.CODEX_SHELL;

    const result = detectRuntime(undefined, '/tmp');
    assert.equal(result.runtime, 'codex');
    assert.equal(result.detectionReason, 'env:codex-originator');

    restoreEnv(envBackup);
  });
});

describe('resolveBundleConfig', () => {
  it('Claude bundle targets agents and plugin skills separately', () => {
    const config = resolveBundleConfig('claude', claudeBundleRoot, '/tmp/.claude');
    assert.equal(config.contextTarget, '/tmp/.claude/CLAUDE.md');
    assert.equal(config.agentsTargetDir, '/tmp/.claude/agents');
    assert.equal(config.skillsTargetDir, '/tmp/.claude/plugins/marketplaces/ai-harness/skills');
    assert.equal(config.agentExtension, '.md');
    assert.equal(config.agentFormat, 'markdown-frontmatter');
  });

  it('Codex bundle targets home-local agents and skills', () => {
    const config = resolveBundleConfig('codex', codexBundleRoot, '/tmp/.codex');
    assert.equal(config.contextTarget, '/tmp/.codex/AGENTS.md');
    assert.equal(config.agentsTargetDir, '/tmp/.codex/agents');
    assert.equal(config.skillsTargetDir, '/tmp/.codex/skills');
    assert.equal(config.agentExtension, '.toml');
    assert.equal(config.agentFormat, 'toml');
  });
});

describe('buildInstallPlan', () => {
  it('Claude bundle plan installs md agents and plugin skills', () => {
    const plan = buildInstallPlan(claudeBundleRoot, 'claude', '/tmp/.claude');
    const targetPaths = new Set(plan.assets.map((asset) => asset.relativeTargetPath));
    const architectAgent = plan.assets.find((asset) => asset.relativeTargetPath === 'agents/architect-reviewer.md');
    const jiraSkill = plan.assets.find((asset) => asset.relativeTargetPath === 'skills/jira/SKILL.md');
    const refreshSkill = plan.assets.find((asset) => asset.relativeTargetPath === 'skills/refresh-planning-subagents/SKILL.md');

    assert.equal(targetPaths.has('agents/architect-reviewer.md'), true);
    assert.equal(targetPaths.has('skills/jira/SKILL.md'), true);
    assert.equal(targetPaths.has('skills/refresh-planning-subagents/SKILL.md'), true);
    assert.equal(architectAgent?.destPath, '/tmp/.claude/agents/architect-reviewer.md');
    assert.equal(jiraSkill?.destPath, '/tmp/.claude/plugins/marketplaces/ai-harness/skills/jira/SKILL.md');
    assert.equal(refreshSkill?.destPath, '/tmp/.claude/plugins/marketplaces/ai-harness/skills/refresh-planning-subagents/SKILL.md');
    assert.equal(plan.sourceAgentCount, 16);
    assert.equal(plan.sourceSkillCount, 27);
  });

  it('Codex bundle plan installs toml agents and home skills', () => {
    const plan = buildInstallPlan(codexBundleRoot, 'codex', '/tmp/.codex');
    const targetPaths = new Set(plan.assets.map((asset) => asset.relativeTargetPath));
    const architectAgent = plan.assets.find((asset) => asset.relativeTargetPath === 'agents/architect-reviewer.toml');
    const jiraSkill = plan.assets.find((asset) => asset.relativeTargetPath === 'skills/jira/SKILL.md');

    assert.equal(targetPaths.has('agents/architect-reviewer.toml'), true);
    assert.equal(targetPaths.has('skills/jira/SKILL.md'), true);
    assert.equal(architectAgent?.destPath, '/tmp/.codex/agents/architect-reviewer.toml');
    assert.equal(jiraSkill?.destPath, '/tmp/.codex/skills/jira/SKILL.md');
    assert.equal(plan.sourceAgentCount, 16);
    assert.equal(plan.sourceSkillCount, 26);
  });
});

describe('isTextFile', () => {
  it('.md 파일은 텍스트로 판별한다', () => {
    assert.equal(isTextFile('readme.md'), true);
  });

  it('.toml 파일은 텍스트로 판별한다', () => {
    assert.equal(isTextFile('config.toml'), true);
  });

  it('.png 파일은 바이너리로 판별한다', () => {
    assert.equal(isTextFile('image.png'), false);
  });

  it('.js 파일은 바이너리로 판별한다', () => {
    assert.equal(isTextFile('script.js'), false);
  });
});
