import { Command } from 'commander';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { registerInit } from './init.js';
import { registerStatus } from './status.js';
import { registerDoctor } from './doctor.js';
import { registerHookTest } from './hook-test.js';
import { registerWhy } from './why.js';
import { registerRules } from './rules.js';
import { registerCost } from './cost.js';
import { registerMetrics } from './metrics.js';
import { registerRollback } from './rollback.js';
import { registerDiagnose } from './diagnose.js';
import { registerBenchmark } from './benchmark.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(__dirname, '..', 'package.json'), 'utf-8'));

const program = new Command();

program
  .name('ai-harness')
  .description('AI 에이전트 제어/검증 프레임워크')
  .version(pkg.version);

registerInit(program);
registerStatus(program);
registerDoctor(program);
registerHookTest(program);
registerWhy(program);
registerRules(program);
registerCost(program);
registerMetrics(program);
registerRollback(program);
registerDiagnose(program);
registerBenchmark(program);

program.parse();
