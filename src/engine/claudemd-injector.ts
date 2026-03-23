import { readFile, writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { dirname } from 'path';

const START_MARKER = '<!-- harness:start -->';
const END_MARKER = '<!-- harness:end -->';
const HEADER = '# ─── AI Harness (자동 생성, 수동 편집 금지) ───';

export async function inject(claudeMdPath: string, content: string): Promise<void> {
  const dir = dirname(claudeMdPath);
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true });
  }

  const harnessSection = `\n${HEADER}\n${START_MARKER}\n${content}\n${END_MARKER}\n`;

  if (!existsSync(claudeMdPath)) {
    await writeFile(claudeMdPath, harnessSection, 'utf-8');
    return;
  }

  const existing = await readFile(claudeMdPath, 'utf-8');

  if (hasHarnessSection(existing)) {
    const updated = replaceHarnessSection(existing, harnessSection);
    await writeFile(claudeMdPath, updated, 'utf-8');
  } else {
    await writeFile(claudeMdPath, existing + '\n' + harnessSection, 'utf-8');
  }
}

export async function remove(claudeMdPath: string): Promise<void> {
  if (!existsSync(claudeMdPath)) return;

  const existing = await readFile(claudeMdPath, 'utf-8');
  if (!hasHarnessSection(existing)) return;

  const headerRegex = new RegExp(`\\n?${escapeRegex(HEADER)}\\n`, 'g');
  let cleaned = removeHarnessSection(existing);
  cleaned = cleaned.replace(headerRegex, '');
  cleaned = cleaned.replace(/\n{3,}/g, '\n\n').trim();

  await writeFile(claudeMdPath, cleaned + '\n', 'utf-8');
}

export function hasHarnessSection(content: string): boolean {
  return content.includes(START_MARKER) && content.includes(END_MARKER);
}

function replaceHarnessSection(content: string, newSection: string): string {
  const headerRegex = new RegExp(`\\n?${escapeRegex(HEADER)}\\n${escapeRegex(START_MARKER)}[\\s\\S]*?${escapeRegex(END_MARKER)}\\n?`);
  return content.replace(headerRegex, newSection);
}

function removeHarnessSection(content: string): string {
  const regex = new RegExp(`${escapeRegex(START_MARKER)}[\\s\\S]*?${escapeRegex(END_MARKER)}\\n?`);
  return content.replace(regex, '');
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
