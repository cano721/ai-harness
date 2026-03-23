import type { HarnessContext } from '../adapters/agent-adapter.js';

export function toClaudeMd(context: HarnessContext): string {
  const sections: string[] = [];

  if (context.global) {
    sections.push(context.global);
  }

  for (const team of context.teams) {
    if (team) {
      sections.push(team);
    }
  }

  return sections.join('\n\n');
}

export function toAgentsMd(context: HarnessContext): string {
  const sections: string[] = ['# Agent Instructions\n'];

  if (context.global) {
    sections.push('## Global Context\n');
    sections.push(context.global);
  }

  if (context.teams.length > 0) {
    sections.push('\n## Team Context\n');
    for (const team of context.teams) {
      if (team) {
        sections.push(team);
      }
    }
  }

  if (Object.keys(context.rules).length > 0) {
    sections.push('\n## Rules\n');
    for (const [key, value] of Object.entries(context.rules)) {
      sections.push(`### ${key}\n`);
      sections.push(typeof value === 'string' ? value : JSON.stringify(value, null, 2));
    }
  }

  return sections.join('\n');
}

export function toCursorRules(context: HarnessContext): string {
  const lines: string[] = [];

  if (context.global) {
    lines.push(context.global);
  }

  for (const team of context.teams) {
    if (team) {
      lines.push(team);
    }
  }

  if (Object.keys(context.rules).length > 0) {
    lines.push('\n# Rules');
    for (const [key, value] of Object.entries(context.rules)) {
      lines.push(`\n## ${key}`);
      lines.push(typeof value === 'string' ? value : JSON.stringify(value, null, 2));
    }
  }

  return lines.join('\n');
}
