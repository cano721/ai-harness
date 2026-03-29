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
  const { name, tool: toolName, input: toolInput, expect_exit: expectExit, expect, expect_output_contains: expectOutput, match, config_override: configOverride } = testCase;
  const inputStr = typeof toolInput === 'string' ? toolInput : JSON.stringify(toolInput);

  // config_override로 비활성화된 경우 스킵
  if (configOverride) {
    const hookName = path.basename(hookPath, '.sh');
    const hookConfig = configOverride?.hooks?.[hookName];
    if (hookConfig && hookConfig.enabled === false) {
      return { name, passed: true, exitCode: 0, expectedExit: 0, output: '(skipped: disabled by config_override)' };
    }
  }

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

  // expect: blocked → exit 2, expect: pass → exit 0
  let expectedExit;
  if (expectExit !== undefined) {
    expectedExit = expectExit;
  } else if (expect === 'blocked') {
    expectedExit = 2;
  } else {
    expectedExit = 0;
  }
  const exitOk = exitCode === expectedExit;
  const matchStr = expectOutput || match;
  const outputOk = matchStr ? output.includes(matchStr) : true;
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
