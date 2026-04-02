import { readFile, readdir, access } from 'fs/promises';
import { join } from 'path';
import { execSync } from 'child_process';
import {
  detectTechStack,
  isGitRepo,
  getGitUrl,
  readConventions,
  readConfig,
} from '@ddalkak/shared';
import type { ProjectAnalysis } from '@ddalkak/shared';

async function pathExists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

function tryExec(cmd: string): boolean {
  try {
    execSync(cmd, { stdio: 'ignore', timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

export async function analyzeProject(projectPath: string): Promise<ProjectAnalysis> {
  if (!(await pathExists(projectPath))) {
    throw new Error(`Project path does not exist: ${projectPath}`);
  }

  const [techStack, conventions, config] = await Promise.all([
    detectTechStack(projectPath),
    readConventions(projectPath),
    readConfig(projectPath),
  ]);

  // Git info
  const gitIsRepo = isGitRepo(projectPath);
  const gitUrl = gitIsRepo ? getGitUrl(projectPath) : undefined;
  let gitBranch: string | undefined;
  if (gitIsRepo) {
    try {
      gitBranch = execSync('git branch --show-current', { cwd: projectPath, encoding: 'utf-8', timeout: 5000 }).trim() || undefined;
    } catch {
      gitBranch = undefined;
    }
  }

  // CLAUDE.md
  const claudeMdPath = join(projectPath, 'CLAUDE.md');
  let claudeMd: ProjectAnalysis['claudeMd'];
  try {
    const content = await readFile(claudeMdPath, 'utf-8');
    claudeMd = { exists: true, content };
  } catch {
    claudeMd = { exists: false };
  }

  // .claude/agents/*.md
  const agentsDir = join(projectPath, '.claude', 'agents');
  let agents: ProjectAnalysis['agents'] = [];
  if (await pathExists(agentsDir)) {
    try {
      const entries = await readdir(agentsDir);
      agents = entries
        .filter(e => e.endsWith('.md'))
        .map(e => ({ name: e.replace(/\.md$/, ''), path: join(agentsDir, e) }));
    } catch {
      agents = [];
    }
  }

  // .claude/settings.json → hooks + mcpServers
  const settingsPath = join(projectPath, '.claude', 'settings.json');
  let hooks: ProjectAnalysis['hooks'] = [];
  let mcpServers: ProjectAnalysis['mcpServers'] = [];
  if (await pathExists(settingsPath)) {
    try {
      const settingsContent = await readFile(settingsPath, 'utf-8');
      const settings = JSON.parse(settingsContent);

      if (settings.hooks && typeof settings.hooks === 'object') {
        hooks = Object.entries(settings.hooks as Record<string, unknown>).map(([event, cmds]) => ({
          event,
          commands: Array.isArray(cmds) ? cmds.map(String) : [String(cmds)],
        }));
      }

      if (settings.mcpServers && typeof settings.mcpServers === 'object') {
        mcpServers = Object.entries(settings.mcpServers as Record<string, unknown>).map(([name, srv]) => {
          const s = srv as Record<string, unknown>;
          return {
            name,
            command: String(s.command ?? ''),
            args: Array.isArray(s.args) ? s.args.map(String) : undefined,
          };
        });
      }
    } catch {
      // settings.json unreadable or invalid JSON — leave as empty arrays
    }
  }

  // .ddalkak/docs/*.md
  const docsDir = join(projectPath, '.ddalkak', 'docs');
  let docs: ProjectAnalysis['docs'] = [];
  if (await pathExists(docsDir)) {
    try {
      const entries = await readdir(docsDir);
      docs = entries
        .filter(e => e.endsWith('.md'))
        .map(e => ({ name: e.replace(/\.md$/, ''), path: join(docsDir, e) }));
    } catch {
      docs = [];
    }
  }

  // .ddalkak/skills/*.md
  const skillsDir = join(projectPath, '.ddalkak', 'skills');
  let skills: ProjectAnalysis['skills'] = [];
  if (await pathExists(skillsDir)) {
    try {
      const entries = await readdir(skillsDir);
      skills = entries
        .filter(e => e.endsWith('.md'))
        .map(e => ({ name: e.replace(/\.md$/, ''), path: join(skillsDir, e) }));
    } catch {
      skills = [];
    }
  }

  // .ddalkak/workflows/*.md
  const workflowsDir = join(projectPath, '.ddalkak', 'workflows');
  let workflows: ProjectAnalysis['workflows'] = [];
  if (await pathExists(workflowsDir)) {
    try {
      const entries = await readdir(workflowsDir);
      workflows = entries
        .filter(e => e.endsWith('.md'))
        .map(e => ({ name: e.replace(/\.md$/, ''), path: join(workflowsDir, e) }));
    } catch {
      workflows = [];
    }
  }

  // CLI detection
  const installedCLIs: ProjectAnalysis['installedCLIs'] = {
    claude: tryExec('claude --version'),
    codex: tryExec('codex --version'),
    cursor: tryExec('cursor --version'),
  };

  // claudeMdQuality: default -1 means "not yet analyzed" (AI analysis done via separate API)
  const claudeMdQuality: ProjectAnalysis['claudeMdQuality'] = {
    score: -1,
    missingSections: [],
    suggestions: [],
  };

  // Guard/Guide/Gear scores
  const hasSecurityInClaudeMd = claudeMd.exists && claudeMd.content
    ? claudeMd.content.toLowerCase().includes('## 보안') || claudeMd.content.toLowerCase().includes('## guard')
    : false;
  const allHookCommands = hooks.flatMap(h => h.commands.join(' ')).join(' ').toLowerCase();
  const hasSecretScannerHook = allHookCommands.includes('secret-scanner');

  const guardDetails: { label: string; done: boolean }[] = [
    { label: '보안 Hook', done: hooks.length > 0 },
    { label: '시크릿 스캔', done: hasSecretScannerHook },
    { label: '보안 규칙 문서화', done: hasSecurityInClaudeMd },
  ];

  const guideDetails: { label: string; done: boolean }[] = [
    { label: 'CLAUDE.md', done: claudeMd.exists },
    { label: '컨벤션', done: docs.some(d => d.name === 'convention') || skills.some(s => s.name === 'convention') },
    { label: '문서', done: docs.length > 0 },
    { label: '스킬', done: skills.length > 0 },
  ];

  const gearDetails: { label: string; done: boolean }[] = [
    { label: '에이전트 CLI', done: installedCLIs.claude || installedCLIs.codex || installedCLIs.cursor },
    { label: '프로젝트 에이전트', done: agents.length > 0 },
    { label: '워크플로우', done: workflows.length > 0 },
  ];

  const calcScore = (details: { label: string; done: boolean }[]) =>
    Math.round((details.filter(d => d.done).length / details.length) * 100);

  const scores: ProjectAnalysis['scores'] = {
    guard: { score: calcScore(guardDetails), details: guardDetails },
    guide: { score: calcScore(guideDetails), details: guideDetails },
    gear: { score: calcScore(gearDetails), details: gearDetails },
  };

  return {
    techStack,
    git: { isRepo: gitIsRepo, url: gitUrl, branch: gitBranch },
    claudeMd,
    agents,
    hooks,
    mcpServers,
    docs,
    skills,
    workflows,
    conventions: conventions.map(c => ({ category: c.category, rule: c.rule })),
    guardrails: config?.guardrails ?? {},
    installedCLIs,
    claudeMdQuality,
    scores,
  };
}
