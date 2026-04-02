import { readdir, readFile, stat } from 'fs/promises';
import { join } from 'path';

export interface Skill {
  name: string;
  content: string;
  path: string;
  updatedAt: number;
}

interface CacheEntry {
  skills: Skill[];
  loadedAt: number;
}

const SKILLS_DIR = '.ddalkak/skills';
const CACHE_TTL_MS = 30_000;

const cache = new Map<string, CacheEntry>();

async function dirExists(path: string): Promise<boolean> {
  try {
    const s = await stat(path);
    return s.isDirectory();
  } catch {
    return false;
  }
}

export async function loadSkills(projectPath: string): Promise<Skill[]> {
  const skillsDir = join(projectPath, SKILLS_DIR);
  const cached = cache.get(skillsDir);
  if (cached && Date.now() - cached.loadedAt < CACHE_TTL_MS) {
    return cached.skills;
  }

  if (!(await dirExists(skillsDir))) {
    cache.set(skillsDir, { skills: [], loadedAt: Date.now() });
    return [];
  }

  let entries: string[];
  try {
    entries = await readdir(skillsDir);
  } catch {
    return [];
  }

  const mdFiles = entries.filter(e => e.endsWith('.md'));
  const skills: Skill[] = [];

  for (const file of mdFiles) {
    const filePath = join(skillsDir, file);
    try {
      const [content, fileStat] = await Promise.all([
        readFile(filePath, 'utf-8'),
        stat(filePath),
      ]);
      skills.push({
        name: file.replace(/\.md$/, ''),
        content,
        path: filePath,
        updatedAt: fileStat.mtimeMs,
      });
    } catch {
      // skip unreadable files
    }
  }

  cache.set(skillsDir, { skills, loadedAt: Date.now() });
  return skills;
}

export async function getSkill(projectPath: string, name: string): Promise<Skill | undefined> {
  const skills = await loadSkills(projectPath);
  return skills.find(s => s.name === name);
}

export function clearSkillCache(projectPath?: string): void {
  if (projectPath) {
    cache.delete(join(projectPath, SKILLS_DIR));
  } else {
    cache.clear();
  }
}
