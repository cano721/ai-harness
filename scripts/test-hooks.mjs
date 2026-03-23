#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
let yaml;
try {
  yaml = require('yaml');
} catch {
  console.error('yaml 패키지가 필요합니다: npm install yaml');
  process.exit(1);
}

function loadTestCases(testYamlPath) {
  const content = fs.readFileSync(testYamlPath, 'utf-8');
  return yaml.parse(content);
}

function runTest(hookPath, testCase) {
  const { name, toolName, toolInput, expectExit, expectOutput } = testCase;
  const inputStr = typeof toolInput === 'string' ? toolInput : JSON.stringify(toolInput);

  let exitCode = 0;
  let output = '';

  try {
    output = execSync(`bash "${hookPath}" "${toolName}" ${JSON.stringify(inputStr)}`, {
      timeout: 10000,
      encoding: 'utf-8',
    });
  } catch (err) {
    exitCode = err.status ?? 1;
    output = err.stdout ?? '';
  }

  const expectedExit = expectExit ?? 0;
  const exitOk = exitCode === expectedExit;
  const outputOk = expectOutput ? output.includes(expectOutput) : true;
  const passed = exitOk && outputOk;

  return { name, passed, exitCode, expectedExit, output: output.trim() };
}

function testHook(hooksDir, hookFile) {
  const hookPath = path.join(hooksDir, hookFile);
  const baseName = hookFile.replace(/\.sh$/, '');
  const testYamlPath = path.join(hooksDir, `${baseName}.test.yaml`);

  if (!fs.existsSync(testYamlPath)) {
    return { hookName: baseName, skipped: true, reason: '테스트 파일 없음' };
  }

  const testData = loadTestCases(testYamlPath);
  const cases = testData.tests ?? testData ?? [];
  const results = cases.map(tc => runTest(hookPath, tc));
  const passed = results.filter(r => r.passed).length;

  return { hookName: baseName, passed, total: results.length, results };
}

const [,, hooksDir, hookName] = process.argv;

if (!hooksDir) {
  console.error('사용법:');
  console.error('  node scripts/test-hooks.mjs <hooksDir> [hookName]');
  process.exit(1);
}

if (!fs.existsSync(hooksDir)) {
  console.error(`디렉토리 없음: ${hooksDir}`);
  process.exit(1);
}

try {
  let hookFiles = fs.readdirSync(hooksDir).filter(f => f.endsWith('.sh'));

  if (hookName) {
    const target = hookName.endsWith('.sh') ? hookName : `${hookName}.sh`;
    hookFiles = hookFiles.filter(f => f === target);
    if (hookFiles.length === 0) {
      console.error(`hook 없음: ${hookName}`);
      process.exit(1);
    }
  }

  const results = hookFiles.map(f => testHook(hooksDir, f));
  const allPassed = results.every(r => r.skipped || r.passed === r.total);

  console.log(JSON.stringify(results, null, 2));
  process.exit(allPassed ? 0 : 1);
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
