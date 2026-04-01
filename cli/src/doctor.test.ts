import { describe, it, expect } from 'vitest';
import { execSync } from 'child_process';
import { join } from 'path';

const CLI_PATH = join(import.meta.dirname, '../dist/index.js');

describe('CLI', () => {
  it('--help prints usage', () => {
    const output = execSync(`node ${CLI_PATH} --help`, { encoding: 'utf-8' });
    expect(output).toContain('ddalkak');
    expect(output).toContain('start');
    expect(output).toContain('doctor');
  });

  it('--version prints version', () => {
    const output = execSync(`node ${CLI_PATH} --version`, { encoding: 'utf-8' });
    expect(output).toContain('3.0.0-alpha.0');
  });

  it('doctor runs without errors', () => {
    const output = execSync(`node ${CLI_PATH} doctor`, { encoding: 'utf-8' });
    expect(output).toContain('ddalkak doctor');
    expect(output).toContain('Node.js');
    expect(output).toContain('Claude Code');
  });

  it('unknown command exits with error', () => {
    try {
      execSync(`node ${CLI_PATH} foobar`, { encoding: 'utf-8', stdio: 'pipe' });
      expect.unreachable('should have thrown');
    } catch (e: any) {
      expect(e.status).toBe(1);
    }
  });
});
