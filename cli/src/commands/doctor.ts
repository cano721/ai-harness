import { existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { execSync } from 'child_process';
import { APP_NAME } from '@ddalkak/shared';

interface Check {
  name: string;
  status: 'ok' | 'warn' | 'fail';
  message: string;
}

export async function doctorCommand() {
  console.log(`\n  ⚡ ${APP_NAME} doctor\n`);

  const checks: Check[] = [];
  const home = homedir();

  // Node.js version
  const nodeVersion = process.versions.node;
  const major = parseInt(nodeVersion.split('.')[0]);
  checks.push({
    name: 'Node.js',
    status: major >= 20 ? 'ok' : major >= 18 ? 'warn' : 'fail',
    message: `v${nodeVersion}${major < 20 ? ' (v20+ recommended)' : ''}`,
  });

  // Data directory
  const dataDir = join(home, '.ddalkak');
  checks.push({
    name: 'Data directory',
    status: existsSync(dataDir) ? 'ok' : 'warn',
    message: existsSync(dataDir) ? dataDir : `${dataDir} (will be created on first start)`,
  });

  // Claude Code
  const claudeConfig = join(home, '.claude', 'settings.json');
  const claudeInstalled = existsSync(claudeConfig);
  let claudeVersion: string | undefined;
  try { claudeVersion = execSync('claude --version', { encoding: 'utf-8', timeout: 5000 }).trim(); } catch {}
  checks.push({
    name: 'Claude Code',
    status: claudeInstalled ? 'ok' : 'warn',
    message: claudeInstalled ? `installed${claudeVersion ? ` (${claudeVersion})` : ''}` : 'not found',
  });

  // Codex
  const codexConfig = join(home, '.codex', 'config.json');
  const codexInstalled = existsSync(codexConfig);
  checks.push({
    name: 'Codex',
    status: codexInstalled ? 'ok' : 'warn',
    message: codexInstalled ? 'installed' : 'not found (optional)',
  });

  // Cursor
  const cursorConfig = join(home, '.cursor', 'settings.json');
  const cursorInstalled = existsSync(cursorConfig);
  checks.push({
    name: 'Cursor',
    status: cursorInstalled ? 'ok' : 'warn',
    message: cursorInstalled ? 'installed' : 'not found (optional)',
  });

  // Print results
  const icons = { ok: '✓', warn: '!', fail: '✕' };
  const colors = { ok: '\x1b[32m', warn: '\x1b[33m', fail: '\x1b[31m' };
  const reset = '\x1b[0m';

  for (const check of checks) {
    console.log(`  ${colors[check.status]}${icons[check.status]}${reset} ${check.name}: ${check.message}`);
  }

  const hasFailures = checks.some((c) => c.status === 'fail');
  console.log(hasFailures ? '\n  Some checks failed. Fix issues above before starting.\n' : '\n  All checks passed. Run `ddalkak start` to begin.\n');

  process.exit(hasFailures ? 1 : 0);
}
