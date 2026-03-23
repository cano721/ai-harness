#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';

function percentile(sorted, p) {
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

function benchmarkHook(hookPath, iterations) {
  const times = [];
  for (let i = 0; i < iterations; i++) {
    const start = process.hrtime.bigint();
    try {
      execSync(`bash "${hookPath}" "test_tool" "{}"`, {
        timeout: 30000,
        stdio: 'ignore',
      });
    } catch {
      // 종료 코드 무시, 시간만 측정
    }
    const end = process.hrtime.bigint();
    times.push(Number(end - start) / 1_000_000); // ms
  }

  const sorted = [...times].sort((a, b) => a - b);
  const avg = times.reduce((s, v) => s + v, 0) / times.length;

  return {
    name: path.basename(hookPath, '.sh'),
    p50: Math.round(percentile(sorted, 50) * 100) / 100,
    p95: Math.round(percentile(sorted, 95) * 100) / 100,
    p99: Math.round(percentile(sorted, 99) * 100) / 100,
    min: Math.round(sorted[0] * 100) / 100,
    max: Math.round(sorted[sorted.length - 1] * 100) / 100,
    avg: Math.round(avg * 100) / 100,
  };
}

const [,, hooksDir, iterationsArg] = process.argv;

if (!hooksDir) {
  console.error('사용법:');
  console.error('  node scripts/benchmark-hooks.mjs <hooksDir> [iterations]');
  process.exit(1);
}

if (!fs.existsSync(hooksDir)) {
  console.error(`디렉토리 없음: ${hooksDir}`);
  process.exit(1);
}

const iterations = parseInt(iterationsArg ?? '10', 10);
if (isNaN(iterations) || iterations < 1) {
  console.error('iterations는 1 이상의 정수여야 합니다.');
  process.exit(1);
}

try {
  const hookFiles = fs.readdirSync(hooksDir).filter(f => f.endsWith('.sh'));

  if (hookFiles.length === 0) {
    console.log(JSON.stringify({ hooks: [] }));
    process.exit(0);
  }

  const hooks = hookFiles.map(f => {
    const hookPath = path.join(hooksDir, f);
    console.error(`벤치마크 중: ${f} (${iterations}회)`);
    return benchmarkHook(hookPath, iterations);
  });

  console.log(JSON.stringify({ hooks }, null, 2));
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
