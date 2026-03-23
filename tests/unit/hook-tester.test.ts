import { describe, it, expect } from 'vitest';
import { join } from 'path';
import { testHook, testAll } from '../../src/engine/hook-tester.js';

const HOOKS_DIR = join(import.meta.dirname, '..', '..', 'hooks');

describe('hook-tester', () => {
  it('block-dangerous Hook 테스트를 실행한다', async () => {
    const results = await testHook(
      join(HOOKS_DIR, 'block-dangerous.sh'),
      join(HOOKS_DIR, 'block-dangerous.test.yaml'),
    );

    expect(results.length).toBeGreaterThan(0);
    const allPassed = results.every((r) => r.passed);
    if (!allPassed) {
      const failed = results.filter((r) => !r.passed);
      console.log('Failed tests:', failed.map((f) => `${f.name}: expected exit ${f.expectedExit}, got ${f.actualExit}`));
    }
    expect(allPassed).toBe(true);
  }, 30000);

  it('secret-scanner Hook 테스트를 실행한다', async () => {
    const results = await testHook(
      join(HOOKS_DIR, 'secret-scanner.sh'),
      join(HOOKS_DIR, 'secret-scanner.test.yaml'),
    );

    expect(results.length).toBeGreaterThan(0);
    const allPassed = results.every((r) => r.passed);
    if (!allPassed) {
      const failed = results.filter((r) => !r.passed);
      console.log('Failed tests:', failed.map((f) => `${f.name}: expected exit ${f.expectedExit}, got ${f.actualExit} | output: ${f.output}`));
    }
    expect(allPassed).toBe(true);
  }, 30000);

  it('audit-logger Hook 테스트를 실행한다', async () => {
    const results = await testHook(
      join(HOOKS_DIR, 'audit-logger.sh'),
      join(HOOKS_DIR, 'audit-logger.test.yaml'),
    );

    expect(results.length).toBeGreaterThan(0);
    expect(results.every((r) => r.passed)).toBe(true);
  }, 30000);

  it('전체 Hook 테스트를 실행한다', async () => {
    const allResults = await testAll(HOOKS_DIR);
    expect(allResults.size).toBe(3);

    for (const [hookName, results] of allResults) {
      const allPassed = results.every((r) => r.passed);
      if (!allPassed) {
        const failed = results.filter((r) => !r.passed);
        console.log(`[${hookName}] Failed:`, failed.map((f) => f.name));
      }
      expect(allPassed).toBe(true);
    }
  }, 60000);

  it('존재하지 않는 Hook 파일에 에러를 던진다', async () => {
    await expect(
      testHook('/nonexistent/hook.sh', '/nonexistent/test.yaml'),
    ).rejects.toThrow('Hook 파일을 찾을 수 없습니다');
  });
});
