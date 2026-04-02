import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdirSync, rmSync, writeFileSync } from 'fs';
import { join } from 'path';
import { loadSkills, getSkill, clearSkillCache } from './skill-loader.service.js';

const TEST_DIR = '/tmp/skill-loader-test';

beforeEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
  mkdirSync(TEST_DIR, { recursive: true });
  clearSkillCache();
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
  clearSkillCache();
});

describe('loadSkills', () => {
  it('returns empty array when .ddalkak/skills does not exist', async () => {
    const skills = await loadSkills(TEST_DIR);
    expect(skills).toEqual([]);
  });

  it('returns empty array when skills dir is empty', async () => {
    mkdirSync(join(TEST_DIR, '.ddalkak', 'skills'), { recursive: true });
    const skills = await loadSkills(TEST_DIR);
    expect(skills).toEqual([]);
  });

  it('loads .md files from .ddalkak/skills/', async () => {
    const skillsDir = join(TEST_DIR, '.ddalkak', 'skills');
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(join(skillsDir, 'my-skill.md'), '# My Skill\nDo something.');
    writeFileSync(join(skillsDir, 'other.md'), '# Other');

    const skills = await loadSkills(TEST_DIR);
    expect(skills).toHaveLength(2);
    const names = skills.map(s => s.name).sort();
    expect(names).toEqual(['my-skill', 'other']);
  });

  it('ignores non-.md files', async () => {
    const skillsDir = join(TEST_DIR, '.ddalkak', 'skills');
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(join(skillsDir, 'skill.md'), '# Skill');
    writeFileSync(join(skillsDir, 'not-a-skill.txt'), 'ignore me');

    const skills = await loadSkills(TEST_DIR);
    expect(skills).toHaveLength(1);
    expect(skills[0].name).toBe('skill');
  });

  it('returns skill with correct content', async () => {
    const skillsDir = join(TEST_DIR, '.ddalkak', 'skills');
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(join(skillsDir, 'convention-backend.md'), '# Backend Convention');

    const skills = await loadSkills(TEST_DIR);
    expect(skills[0].content).toBe('# Backend Convention');
    expect(skills[0].name).toBe('convention-backend');
  });

  it('returns cached result on second call within TTL', async () => {
    const skillsDir = join(TEST_DIR, '.ddalkak', 'skills');
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(join(skillsDir, 'skill.md'), '# Skill');

    const first = await loadSkills(TEST_DIR);
    // Add a new file — should still be cached
    writeFileSync(join(skillsDir, 'new-skill.md'), '# New');
    const second = await loadSkills(TEST_DIR);
    expect(second).toHaveLength(first.length);
  });
});

describe('getSkill', () => {
  it('returns undefined for non-existent skill', async () => {
    mkdirSync(join(TEST_DIR, '.ddalkak', 'skills'), { recursive: true });
    const skill = await getSkill(TEST_DIR, 'nonexistent');
    expect(skill).toBeUndefined();
  });

  it('returns skill by name', async () => {
    const skillsDir = join(TEST_DIR, '.ddalkak', 'skills');
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(join(skillsDir, 'deploy.md'), '# Deploy');

    const skill = await getSkill(TEST_DIR, 'deploy');
    expect(skill).toBeDefined();
    expect(skill!.name).toBe('deploy');
    expect(skill!.content).toBe('# Deploy');
  });
});

describe('clearSkillCache', () => {
  it('clears cache for specific project', async () => {
    const skillsDir = join(TEST_DIR, '.ddalkak', 'skills');
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(join(skillsDir, 'skill.md'), '# Skill');

    await loadSkills(TEST_DIR);
    clearSkillCache(TEST_DIR);

    // Add new file — should be picked up after cache cleared
    writeFileSync(join(skillsDir, 'new-skill.md'), '# New Skill');
    const skills = await loadSkills(TEST_DIR);
    expect(skills).toHaveLength(2);
  });
});
