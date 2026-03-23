import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { join } from 'path';
import { mkdtemp, rm, readFile, writeFile, cp } from 'fs/promises';
import { tmpdir } from 'os';
import { inject, remove, hasHarnessSection } from '../../src/engine/claudemd-injector.js';

const FIXTURES = join(import.meta.dirname, '..', 'fixtures');

describe('claudemd-injector', () => {
  let tmpDir: string;
  let testFile: string;

  beforeEach(async () => {
    tmpDir = await mkdtemp(join(tmpdir(), 'harness-test-'));
    testFile = join(tmpDir, 'CLAUDE.md');
  });

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  it('빈 파일에 하네스 구간을 생성한다', async () => {
    await inject(testFile, '## 보안 규칙\n- 시크릿 금지');
    const content = await readFile(testFile, 'utf-8');
    expect(content).toContain('<!-- harness:start -->');
    expect(content).toContain('## 보안 규칙');
    expect(content).toContain('<!-- harness:end -->');
  });

  it('기존 CLAUDE.md 내용을 보존한다', async () => {
    await cp(join(FIXTURES, 'sample-claude.md'), testFile);
    await inject(testFile, '## 하네스 규칙');
    const content = await readFile(testFile, 'utf-8');
    expect(content).toContain('우리 프로젝트 규칙');
    expect(content).toContain('## 하네스 규칙');
  });

  it('기존 하네스 구간을 업데이트한다', async () => {
    await inject(testFile, '## 버전 1');
    await inject(testFile, '## 버전 2');
    const content = await readFile(testFile, 'utf-8');
    expect(content).not.toContain('버전 1');
    expect(content).toContain('버전 2');
    // start/end 마커가 한 쌍만 존재
    expect(content.match(/harness:start/g)?.length).toBe(1);
  });

  it('하네스 구간을 제거한다', async () => {
    await cp(join(FIXTURES, 'sample-claude.md'), testFile);
    await inject(testFile, '## 하네스 규칙');
    await remove(testFile);
    const content = await readFile(testFile, 'utf-8');
    expect(content).toContain('우리 프로젝트 규칙');
    expect(content).not.toContain('harness:start');
    expect(content).not.toContain('하네스 규칙');
  });

  it('hasHarnessSection이 올바르게 판단한다', () => {
    expect(hasHarnessSection('<!-- harness:start -->\ntest\n<!-- harness:end -->')).toBe(true);
    expect(hasHarnessSection('no harness here')).toBe(false);
  });
});
