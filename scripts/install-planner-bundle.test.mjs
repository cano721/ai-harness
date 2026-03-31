import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { detectRuntime, transformText, parseArgs, isTextFile } from './install-planner-bundle.mjs';

// --- parseArgs ---
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

// --- transformText ---
describe('transformText', () => {
  const vars = { targetRootAbs: '/home/user/.claude', targetRootTilde: '~/.claude' };

  it('단순 문자열 치환을 수행한다', () => {
    const result = transformText('Edit ~/.codex/config.toml', [
      { from: '~/.codex/config.toml', to: '~/.claude/settings.json' },
    ], vars);
    assert.equal(result, 'Edit ~/.claude/settings.json');
  });

  it('여러 치환을 순서대로 적용한다', () => {
    const result = transformText('~/.codex and $HOME/.codex', [
      { from: '~/.codex', to: '{{TARGET_ROOT_TILDE}}' },
      { from: '$HOME/.codex', to: '$HOME/.claude' },
    ], vars);
    assert.equal(result, '~/.claude and $HOME/.claude');
  });

  it('치환 대상이 없으면 원본을 그대로 반환한다', () => {
    const input = 'no match here';
    const result = transformText(input, [
      { from: 'something', to: 'else' },
    ], vars);
    assert.equal(result, input);
  });

  it('{{TARGET_ROOT_ABS}} 플레이스홀더를 보간한다', () => {
    const result = transformText('path is here', [
      { from: 'path', to: '{{TARGET_ROOT_ABS}}' },
    ], vars);
    assert.equal(result, '/home/user/.claude is here');
  });
});

// --- detectRuntime ---
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

  it('scriptPath에 .claude가 포함되면 claude를 반환한다', () => {
    const envBackup = { ...process.env };
    delete process.env.CODEX_THREAD_ID;
    delete process.env.CODEX_SHELL;
    delete process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
    delete process.env.CLAUDECODE;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CLAUDE_PROJECT_DIR;

    const result = detectRuntime(undefined, '/home/user/.claude/scripts');
    assert.equal(result.runtime, 'claude');
    assert.equal(result.detectionReason, 'path:.claude');

    Object.assign(process.env, envBackup);
  });

  it('scriptPath에 .codex가 포함되면 codex를 반환한다', () => {
    const envBackup = { ...process.env };
    delete process.env.CODEX_THREAD_ID;
    delete process.env.CODEX_SHELL;
    delete process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
    delete process.env.CLAUDECODE;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CLAUDE_PROJECT_DIR;

    const result = detectRuntime(undefined, '/home/user/.codex/scripts');
    assert.equal(result.runtime, 'codex');
    assert.equal(result.detectionReason, 'path:.codex');

    Object.assign(process.env, envBackup);
  });
});

// --- isTextFile ---
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
