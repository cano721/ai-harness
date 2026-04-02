import { readFile, writeFile, mkdir, access, readdir, copyFile } from 'fs/promises';
import { join, relative } from 'path';
import { existsSync } from 'fs';
import { execSync } from 'child_process';

const DDALKAK_DIR = '.ddalkak';
const CONFIG_FILE = 'config.yaml';
const CONVENTIONS_FILE = 'conventions.yaml';
const RELATIONS_FILE = 'relations.yaml';

export interface DdalkakConfig {
  name: string;
  description?: string;
  gitUrl?: string;
  techStack?: string[];
  guardrails: Record<string, string | number>;
}

export interface DdalkakConvention {
  category: string;
  rule: string;
  scope: string;
  enabled: boolean;
}

// --- .ddalkak/ folder management ---

export async function ensureDdalkakDir(projectPath: string): Promise<string> {
  const dir = join(projectPath, DDALKAK_DIR);
  await mkdir(dir, { recursive: true });
  await mkdir(join(dir, 'agents'), { recursive: true });
  await mkdir(join(dir, 'skills'), { recursive: true });
  await mkdir(join(dir, 'hooks'), { recursive: true });
  return dir;
}

export async function ddalkakDirExists(projectPath: string): Promise<boolean> {
  try {
    await access(join(projectPath, DDALKAK_DIR));
    return true;
  } catch {
    return false;
  }
}

// --- Config YAML ---

export async function writeConfig(projectPath: string, config: DdalkakConfig): Promise<void> {
  const dir = await ensureDdalkakDir(projectPath);
  const yaml = configToYaml(config);
  await writeFile(join(dir, CONFIG_FILE), yaml, 'utf-8');
}

export async function readConfig(projectPath: string): Promise<DdalkakConfig | null> {
  const filePath = join(projectPath, DDALKAK_DIR, CONFIG_FILE);
  try {
    const content = await readFile(filePath, 'utf-8');
    return yamlToConfig(content);
  } catch {
    return null;
  }
}

// --- Conventions YAML ---

export async function writeConventions(projectPath: string, conventions: DdalkakConvention[]): Promise<void> {
  const dir = await ensureDdalkakDir(projectPath);
  const yaml = conventionsToYaml(conventions);
  await writeFile(join(dir, CONVENTIONS_FILE), yaml, 'utf-8');
}

export async function readConventions(projectPath: string): Promise<DdalkakConvention[]> {
  const filePath = join(projectPath, DDALKAK_DIR, CONVENTIONS_FILE);
  try {
    const content = await readFile(filePath, 'utf-8');
    return yamlToConventions(content);
  } catch {
    return [];
  }
}

// --- Relations YAML ---

export async function writeRelations(projectPath: string, relations: { targetName: string; type: string }[]): Promise<void> {
  const dir = await ensureDdalkakDir(projectPath);
  const lines = ['relations:'];
  for (const r of relations) {
    lines.push(`  - target: "${r.targetName}"`);
    lines.push(`    type: ${r.type}`);
  }
  await writeFile(join(dir, RELATIONS_FILE), lines.join('\n') + '\n', 'utf-8');
}

// --- Tech stack detection ---

export async function detectTechStack(projectPath: string): Promise<string[]> {
  const stack: string[] = [];
  const exists = (f: string) => existsSync(join(projectPath, f));

  if (exists('build.gradle') || exists('build.gradle.kts')) stack.push('Gradle');
  if (exists('pom.xml')) stack.push('Maven');
  if (exists('package.json')) stack.push('Node.js');
  if (exists('tsconfig.json')) stack.push('TypeScript');
  if (exists('next.config.js') || exists('next.config.ts') || exists('next.config.mjs')) stack.push('Next.js');
  if (exists('vite.config.ts') || exists('vite.config.js')) stack.push('Vite');
  if (exists('tailwind.config.js') || exists('tailwind.config.ts')) stack.push('TailwindCSS');
  if (exists('Dockerfile')) stack.push('Docker');
  if (exists('docker-compose.yml') || exists('docker-compose.yaml')) stack.push('Docker Compose');
  if (exists('terraform')) stack.push('Terraform');
  if (exists('requirements.txt') || exists('pyproject.toml')) stack.push('Python');
  if (exists('go.mod')) stack.push('Go');
  if (exists('Cargo.toml')) stack.push('Rust');

  // Detect frameworks from package.json
  if (exists('package.json')) {
    try {
      const pkg = JSON.parse(await readFile(join(projectPath, 'package.json'), 'utf-8'));
      const deps = { ...pkg.dependencies, ...pkg.devDependencies };
      if (deps['react']) stack.push('React');
      if (deps['vue']) stack.push('Vue');
      if (deps['express']) stack.push('Express');
      if (deps['spring-boot'] || deps['@spring']) stack.push('Spring Boot');
    } catch {}
  }

  // Detect Spring Boot from Gradle
  if (exists('build.gradle')) {
    try {
      const gradle = await readFile(join(projectPath, 'build.gradle'), 'utf-8');
      if (gradle.includes('spring-boot')) stack.push('Spring Boot');
      if (gradle.includes('java')) stack.push('Java');
    } catch {}
  }

  return [...new Set(stack)];
}

// --- Git detection ---

export function isGitRepo(projectPath: string): boolean {
  if (existsSync(join(projectPath, '.git'))) return true;
  try {
    const toplevel = execSync('git rev-parse --show-toplevel', {
      cwd: projectPath,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    }).trim();
    return toplevel === projectPath || toplevel === projectPath.replace(/\/$/, '');
  } catch {
    return false;
  }
}

export function getGitUrl(projectPath: string): string | undefined {
  try {
    return execSync('git config --get remote.origin.url', {
      cwd: projectPath,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    }).trim();
  } catch {
    return undefined;
  }
}

// --- Migration from .ai-harness/ ---

export interface MigrateOptions {
  dryRun?: boolean;
  force?: boolean;
}

export interface MigrateResult {
  migrated: boolean;
  details: MigrateDetail[];
}

export interface MigrateDetail {
  status: 'migrated' | 'skipped' | 'error';
  message: string;
}

async function copyDirRecursive(
  srcDir: string,
  destDir: string,
  options: MigrateOptions,
  details: MigrateDetail[],
): Promise<void> {
  const entries = await readdir(srcDir, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    const srcPath = join(srcDir, entry.name);
    const destPath = join(destDir, entry.name);
    if (entry.isDirectory()) {
      if (!options.dryRun) await mkdir(destPath, { recursive: true });
      await copyDirRecursive(srcPath, destPath, options, details);
    } else {
      const relPath = relative(srcDir, srcPath);
      if (existsSync(destPath) && !options.force) {
        details.push({ status: 'skipped', message: `Skipped (already exists): ${entry.name}` });
        continue;
      }
      if (!options.dryRun) {
        await mkdir(destDir, { recursive: true });
        await copyFile(srcPath, destPath);
      }
      details.push({ status: 'migrated', message: `Migrated: ${entry.name}` });
    }
  }
}

export async function migrateFromAiHarness(
  projectPath: string,
  options: MigrateOptions = {},
): Promise<MigrateResult> {
  const oldDir = join(projectPath, '.ai-harness');
  const details: MigrateDetail[] = [];

  if (!existsSync(oldDir)) {
    return { migrated: false, details: [{ status: 'skipped', message: 'No .ai-harness/ directory found' }] };
  }

  if (!options.dryRun) await ensureDdalkakDir(projectPath);
  const newDir = join(projectPath, DDALKAK_DIR);

  // Migrate config.yaml
  const oldConfig = join(oldDir, 'config.yaml');
  if (existsSync(oldConfig)) {
    const destConfig = join(newDir, CONFIG_FILE);
    if (existsSync(destConfig) && !options.force) {
      details.push({ status: 'skipped', message: 'Skipped (already exists): config.yaml' });
    } else {
      if (!options.dryRun) {
        const content = await readFile(oldConfig, 'utf-8');
        await writeFile(destConfig, content, 'utf-8');
      }
      details.push({ status: 'migrated', message: 'Migrated config.yaml' });
    }
  }

  // Migrate context-map.md
  const contextMap = join(oldDir, 'context-map.md');
  if (existsSync(contextMap)) {
    const destMap = join(newDir, 'context-map.md');
    if (existsSync(destMap) && !options.force) {
      details.push({ status: 'skipped', message: 'Skipped (already exists): context-map.md' });
    } else {
      if (!options.dryRun) {
        const content = await readFile(contextMap, 'utf-8');
        await writeFile(destMap, content, 'utf-8');
      }
      details.push({ status: 'migrated', message: 'Migrated context-map.md' });
    }
  }

  // Migrate teams/ conventions
  const teamsDir = join(oldDir, 'teams');
  if (existsSync(teamsDir)) {
    const teams = await readdir(teamsDir).catch(() => []);
    for (const team of teams) {
      const convFile = join(teamsDir, team, 'skills', `convention-${team}.md`);
      if (existsSync(convFile)) {
        const destFile = join(newDir, 'skills', `convention-${team}.md`);
        if (existsSync(destFile) && !options.force) {
          details.push({ status: 'skipped', message: `Skipped (already exists): convention-${team}.md` });
        } else {
          if (!options.dryRun) {
            await mkdir(join(newDir, 'skills'), { recursive: true });
            const content = await readFile(convFile, 'utf-8');
            await writeFile(destFile, content, 'utf-8');
          }
          details.push({ status: 'migrated', message: `Migrated convention-${team}.md` });
        }
      }
    }
  }

  // Migrate .ai-harness/agents/ → .ddalkak/agents/
  const oldAgentsDir = join(oldDir, 'agents');
  if (existsSync(oldAgentsDir)) {
    await copyDirRecursive(oldAgentsDir, join(newDir, 'agents'), options, details);
  }

  // Migrate .ai-harness/skills/ → .ddalkak/skills/
  const oldSkillsDir = join(oldDir, 'skills');
  if (existsSync(oldSkillsDir)) {
    await copyDirRecursive(oldSkillsDir, join(newDir, 'skills'), options, details);
  }

  // Migrate teams/*/skills/ → .ddalkak/skills/ (all skill files, not just conventions)
  if (existsSync(teamsDir)) {
    const teams = await readdir(teamsDir).catch(() => []);
    for (const team of teams) {
      const teamSkillsDir = join(teamsDir, team, 'skills');
      if (existsSync(teamSkillsDir)) {
        await copyDirRecursive(teamSkillsDir, join(newDir, 'skills'), options, details);
      }
    }
  }

  // Migrate .ai-harness/hooks/ → .ddalkak/hooks/
  const oldHooksDir = join(oldDir, 'hooks');
  if (existsSync(oldHooksDir)) {
    await copyDirRecursive(oldHooksDir, join(newDir, 'hooks'), options, details);
  }

  return { migrated: true, details };
}

// --- Simple YAML helpers (avoid adding yaml dep to server) ---

function configToYaml(config: DdalkakConfig): string {
  const lines: string[] = [
    `name: "${config.name}"`,
  ];
  if (config.description) lines.push(`description: "${config.description}"`);
  if (config.gitUrl) lines.push(`git_url: "${config.gitUrl}"`);
  if (config.techStack?.length) {
    lines.push('tech_stack:');
    for (const t of config.techStack) lines.push(`  - "${t}"`);
  }
  if (Object.keys(config.guardrails).length) {
    lines.push('guardrails:');
    for (const [k, v] of Object.entries(config.guardrails)) {
      lines.push(`  ${k}: ${v}`);
    }
  }
  return lines.join('\n') + '\n';
}

function yamlToConfig(content: string): DdalkakConfig {
  const config: DdalkakConfig = { name: '', guardrails: {} };
  const lines = content.split('\n');
  let section = '';

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('name:')) config.name = trimmed.replace('name:', '').trim().replace(/"/g, '');
    else if (trimmed.startsWith('description:')) config.description = trimmed.replace('description:', '').trim().replace(/"/g, '');
    else if (trimmed.startsWith('git_url:')) config.gitUrl = trimmed.replace('git_url:', '').trim().replace(/"/g, '');
    else if (trimmed === 'tech_stack:') { section = 'tech_stack'; config.techStack = []; }
    else if (trimmed === 'guardrails:') section = 'guardrails';
    else if (section === 'tech_stack' && trimmed.startsWith('-')) {
      config.techStack!.push(trimmed.replace(/^-\s*"?/, '').replace(/"$/, ''));
    }
    else if (section === 'guardrails' && trimmed.includes(':')) {
      const [k, v] = trimmed.split(':').map(s => s.trim());
      config.guardrails[k] = isNaN(Number(v)) ? v : Number(v);
    }
  }
  return config;
}

function conventionsToYaml(conventions: DdalkakConvention[]): string {
  const lines = ['conventions:'];
  for (const c of conventions) {
    lines.push(`  - category: "${c.category}"`);
    lines.push(`    rule: "${c.rule}"`);
    lines.push(`    scope: ${c.scope}`);
    lines.push(`    enabled: ${c.enabled}`);
  }
  return lines.join('\n') + '\n';
}

function yamlToConventions(content: string): DdalkakConvention[] {
  const conventions: DdalkakConvention[] = [];
  const lines = content.split('\n');
  let current: Partial<DdalkakConvention> | null = null;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('- category:')) {
      if (current?.category && current?.rule) conventions.push(current as DdalkakConvention);
      current = { category: trimmed.replace('- category:', '').trim().replace(/"/g, ''), scope: 'project', enabled: true, rule: '' };
    } else if (current) {
      if (trimmed.startsWith('rule:')) current.rule = trimmed.replace('rule:', '').trim().replace(/"/g, '');
      else if (trimmed.startsWith('scope:')) current.scope = trimmed.replace('scope:', '').trim();
      else if (trimmed.startsWith('enabled:')) current.enabled = trimmed.replace('enabled:', '').trim() === 'true';
    }
  }
  if (current?.category && current?.rule) conventions.push(current as DdalkakConvention);

  return conventions;
}
