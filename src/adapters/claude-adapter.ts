import { execFile } from 'child_process';
import { promisify } from 'util';
import { existsSync } from 'fs';
import { join } from 'path';
import * as claudemdInjector from '../engine/claudemd-injector.js';
import * as settingsManager from '../engine/settings-manager.js';
import type { AgentAdapter, AgentCapabilities, DetectResult, HarnessContext, HarnessHook } from './agent-adapter.js';

const execFileAsync = promisify(execFile);

const CLAUDE_CONFIG_DIR = join(process.env.HOME ?? '', '.claude');
const CLAUDE_MD_PATH = join(CLAUDE_CONFIG_DIR, 'CLAUDE.md');
const SETTINGS_PATH = join(CLAUDE_CONFIG_DIR, 'settings.json');

export class ClaudeAdapter implements AgentAdapter {
  readonly name = 'claude';

  readonly capabilities: AgentCapabilities = {
    contextInjection: true,
    hooks: 'full',
    mcp: 'native',
    settingsFile: true,
    hierarchicalContext: true,
  };

  async detect(): Promise<DetectResult> {
    try {
      const { stdout } = await execFileAsync('claude', ['--version']);
      const version = stdout.trim();
      const configDir = existsSync(CLAUDE_CONFIG_DIR) ? CLAUDE_CONFIG_DIR : undefined;
      return { installed: true, version, configDir };
    } catch {
      return { installed: false };
    }
  }

  async injectContext(context: HarnessContext): Promise<void> {
    const content = [context.global, ...context.teams].filter(Boolean).join('\n\n');
    await claudemdInjector.inject(CLAUDE_MD_PATH, content);
  }

  async registerHooks(hooks: HarnessHook[]): Promise<void> {
    await settingsManager.registerHooks(SETTINGS_PATH, hooks);
  }

  async cleanup(): Promise<void> {
    await claudemdInjector.remove(CLAUDE_MD_PATH);
    await settingsManager.unregisterHooks(SETTINGS_PATH);
  }
}
