import { execFile } from 'child_process';
import { promisify } from 'util';
import { existsSync } from 'fs';
import { readFile, writeFile, mkdir } from 'fs/promises';
import { join, dirname } from 'path';
import type { AgentAdapter, AgentCapabilities, DetectResult, HarnessContext, HarnessHook } from './agent-adapter.js';

const execFileAsync = promisify(execFile);

const AGENTS_MD_PATH = join(process.cwd(), 'AGENTS.md');
const CODEX_YAML_PATH = join(process.cwd(), 'codex.yaml');

const START_MARKER = '<!-- harness:start -->';
const END_MARKER = '<!-- harness:end -->';
const HEADER = '# ─── AI Harness (자동 생성, 수동 편집 금지) ───';

export class CodexAdapter implements AgentAdapter {
  readonly name = 'codex';

  readonly capabilities: AgentCapabilities = {
    contextInjection: true,
    hooks: 'partial',
    mcp: 'partial',
    settingsFile: false,
    hierarchicalContext: false,
  };

  async detect(): Promise<DetectResult> {
    try {
      const { stdout } = await execFileAsync('codex', ['--version']);
      return { installed: true, version: stdout.trim() };
    } catch {
      return { installed: false };
    }
  }

  async injectContext(context: HarnessContext): Promise<void> {
    const content = [context.global, ...context.teams].filter(Boolean).join('\n\n');
    const harnessSection = `\n${HEADER}\n${START_MARKER}\n${content}\n${END_MARKER}\n`;

    const dir = dirname(AGENTS_MD_PATH);
    if (!existsSync(dir)) {
      await mkdir(dir, { recursive: true });
    }

    if (!existsSync(AGENTS_MD_PATH)) {
      await writeFile(AGENTS_MD_PATH, harnessSection, 'utf-8');
      return;
    }

    const existing = await readFile(AGENTS_MD_PATH, 'utf-8');

    if (existing.includes(START_MARKER) && existing.includes(END_MARKER)) {
      const updated = replaceHarnessSection(existing, harnessSection);
      await writeFile(AGENTS_MD_PATH, updated, 'utf-8');
    } else {
      await writeFile(AGENTS_MD_PATH, existing + '\n' + harnessSection, 'utf-8');
    }
  }

  async registerHooks(hooks: HarnessHook[]): Promise<void> {
    const preHooks = hooks.filter((h) => h.event === 'pre');
    const postHooks = hooks.filter((h) => h.event === 'post');

    const yaml = [
      '# AI Harness managed hooks',
      preHooks.length > 0 ? `pre:\n${preHooks.map((h) => `  - command: "${h.command}"`).join('\n')}` : '',
      postHooks.length > 0 ? `post:\n${postHooks.map((h) => `  - command: "${h.command}"`).join('\n')}` : '',
    ]
      .filter(Boolean)
      .join('\n');

    await writeFile(CODEX_YAML_PATH, yaml + '\n', 'utf-8');
  }

  async cleanup(): Promise<void> {
    if (!existsSync(AGENTS_MD_PATH)) return;

    const existing = await readFile(AGENTS_MD_PATH, 'utf-8');
    if (!existing.includes(START_MARKER)) return;

    const headerRegex = new RegExp(`\\n?${escapeRegex(HEADER)}\\n`, 'g');
    const sectionRegex = new RegExp(`${escapeRegex(START_MARKER)}[\\s\\S]*?${escapeRegex(END_MARKER)}\\n?`);

    let cleaned = existing.replace(sectionRegex, '');
    cleaned = cleaned.replace(headerRegex, '');
    cleaned = cleaned.replace(/\n{3,}/g, '\n\n').trim();

    await writeFile(AGENTS_MD_PATH, cleaned + '\n', 'utf-8');
  }
}

function replaceHarnessSection(content: string, newSection: string): string {
  const headerRegex = new RegExp(
    `\\n?${escapeRegex(HEADER)}\\n${escapeRegex(START_MARKER)}[\\s\\S]*?${escapeRegex(END_MARKER)}\\n?`,
  );
  return content.replace(headerRegex, newSection);
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
