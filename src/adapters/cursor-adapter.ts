import { existsSync } from 'fs';
import { readFile, writeFile, mkdir } from 'fs/promises';
import { join, dirname } from 'path';
import type { AgentAdapter, AgentCapabilities, DetectResult, HarnessContext } from './agent-adapter.js';

const CURSOR_DIR = join(process.cwd(), '.cursor');
const CURSOR_RULES_PATH = join(process.cwd(), '.cursorrules');

const START_MARKER = '# harness:start';
const END_MARKER = '# harness:end';
const HEADER = '# ─── AI Harness (자동 생성, 수동 편집 금지) ───';

export class CursorAdapter implements AgentAdapter {
  readonly name = 'cursor';

  readonly capabilities: AgentCapabilities = {
    contextInjection: true,
    hooks: 'none',
    mcp: 'none',
    settingsFile: false,
    hierarchicalContext: false,
  };

  async detect(): Promise<DetectResult> {
    const installed = existsSync(CURSOR_DIR);
    return { installed, configDir: installed ? CURSOR_DIR : undefined };
  }

  async injectContext(context: HarnessContext): Promise<void> {
    const content = [context.global, ...context.teams].filter(Boolean).join('\n\n');
    const harnessSection = `\n${HEADER}\n${START_MARKER}\n${content}\n${END_MARKER}\n`;

    const dir = dirname(CURSOR_RULES_PATH);
    if (!existsSync(dir)) {
      await mkdir(dir, { recursive: true });
    }

    if (!existsSync(CURSOR_RULES_PATH)) {
      await writeFile(CURSOR_RULES_PATH, harnessSection, 'utf-8');
      return;
    }

    const existing = await readFile(CURSOR_RULES_PATH, 'utf-8');

    if (existing.includes(START_MARKER) && existing.includes(END_MARKER)) {
      const updated = replaceHarnessSection(existing, harnessSection);
      await writeFile(CURSOR_RULES_PATH, updated, 'utf-8');
    } else {
      await writeFile(CURSOR_RULES_PATH, existing + '\n' + harnessSection, 'utf-8');
    }
  }

  async cleanup(): Promise<void> {
    if (!existsSync(CURSOR_RULES_PATH)) return;

    const existing = await readFile(CURSOR_RULES_PATH, 'utf-8');
    if (!existing.includes(START_MARKER)) return;

    const headerRegex = new RegExp(`\\n?${escapeRegex(HEADER)}\\n`, 'g');
    const sectionRegex = new RegExp(`${escapeRegex(START_MARKER)}[\\s\\S]*?${escapeRegex(END_MARKER)}\\n?`);

    let cleaned = existing.replace(sectionRegex, '');
    cleaned = cleaned.replace(headerRegex, '');
    cleaned = cleaned.replace(/\n{3,}/g, '\n\n').trim();

    await writeFile(CURSOR_RULES_PATH, cleaned + '\n', 'utf-8');
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
