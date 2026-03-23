import { readFile } from 'fs/promises';
import { existsSync } from 'fs';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { parse } from 'yaml';
import { join, dirname } from 'path';
import type { HookTestDef, HookTestResult } from '../types/index.js';

const execFileAsync = promisify(execFile);

export async function testHook(
  hookPath: string,
  testDefPath: string,
): Promise<HookTestResult[]> {
  if (!existsSync(hookPath)) {
    throw new Error(`Hook 파일을 찾을 수 없습니다: ${hookPath}`);
  }
  if (!existsSync(testDefPath)) {
    throw new Error(`테스트 정의 파일을 찾을 수 없습니다: ${testDefPath}`);
  }

  const raw = await readFile(testDefPath, 'utf-8');
  const def = parse(raw) as HookTestDef;

  const results: HookTestResult[] = [];

  for (const testCase of def.tests) {
    const result = await runSingleTest(hookPath, testCase);
    results.push(result);
  }

  return results;
}

export async function testAll(hooksDir: string): Promise<Map<string, HookTestResult[]>> {
  const { readdirSync } = await import('fs');
  const files = readdirSync(hooksDir).filter((f) => f.endsWith('.sh'));
  const allResults = new Map<string, HookTestResult[]>();

  for (const file of files) {
    const hookPath = join(hooksDir, file);
    const testPath = join(hooksDir, file.replace('.sh', '.test.yaml'));
    if (existsSync(testPath)) {
      const results = await testHook(hookPath, testPath);
      allResults.set(file, results);
    }
  }

  return allResults;
}

async function runSingleTest(
  hookPath: string,
  testCase: { name: string; tool: string; input: string; expect_exit: number; expect_output_contains?: string },
): Promise<HookTestResult> {
  let actualExit = 0;
  let output = '';

  try {
    const { stdout, stderr } = await execFileAsync('bash', [hookPath, testCase.tool, testCase.input], {
      timeout: 10000,
      cwd: dirname(hookPath),
    });
    output = stdout + stderr;
  } catch (err: unknown) {
    const execErr = err as { code?: number; stdout?: string; stderr?: string };
    actualExit = execErr.code ?? 1;
    output = (execErr.stdout ?? '') + (execErr.stderr ?? '');
  }

  let passed = actualExit === testCase.expect_exit;
  if (passed && testCase.expect_output_contains) {
    passed = output.includes(testCase.expect_output_contains);
  }

  return {
    name: testCase.name,
    tool: testCase.tool,
    input: testCase.input,
    expectedExit: testCase.expect_exit,
    actualExit,
    passed,
    output: output.trim(),
  };
}
