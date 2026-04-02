import { existsSync } from 'fs';
import { writeFile, access } from 'fs/promises';
import { resolve, join } from 'path';
import { execSync } from 'child_process';
import {
  APP_NAME,
  ensureDdalkakDir,
  writeConfig,
  detectTechStack,
  isGitRepo,
  getGitUrl,
  ddalkakDirExists,
} from '@ddalkak/shared';

const DDALKAK_API = 'http://127.0.0.1:7777';

const SKILLS_DOC = `# Ddalkak Agent Protocol

이 프로젝트는 Ddalkak 플랫폼으로 관리됩니다.

## 환경변수
에이전트 실행 시 다음 환경변수가 주입됩니다:
- DDALKAK_AGENT_ID: 에이전트 식별자
- DDALKAK_API_URL: Ddalkak API 주소 (기본: http://127.0.0.1:7777)
- DDALKAK_RUN_ID: 현재 실행 ID
- DDALKAK_TASK_ID: 할당된 태스크 ID
- DDALKAK_PROJECT_ID: 프로젝트 ID

## API 사용법

### 내 정보 조회
GET /api/agents/me
Header: x-ddalkak-agent-id: {DDALKAK_AGENT_ID}

### 할당된 태스크 조회
GET /api/agents/me/inbox
Header: x-ddalkak-agent-id: {DDALKAK_AGENT_ID}

### 태스크 상태 업데이트
PATCH /api/tasks/{taskId}
Body: { "status": "done" | "blocked" }

### 하트비트 전송
POST /api/agents/{DDALKAK_AGENT_ID}/heartbeat

## 컨벤션
이 프로젝트의 코딩 컨벤션은 .ddalkak/conventions.yaml을 참고하세요.

## 가드레일
이 프로젝트의 제한사항은 .ddalkak/config.yaml의 guardrails 섹션을 참고하세요.
`;

async function isServerRunning(): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 2000);
    const res = await fetch(`${DDALKAK_API}/api/health`, { signal: controller.signal });
    clearTimeout(timer);
    return res.ok;
  } catch {
    return false;
  }
}

function detectAgents(): string[] {
  const agents: string[] = [];
  const candidates = ['claude', 'codex', 'cursor'];
  for (const agent of candidates) {
    try {
      execSync(`${agent} --version`, { stdio: 'ignore', timeout: 3000 });
      agents.push(agent);
    } catch {
      // not installed
    }
  }
  return agents;
}

async function registerProject(name: string, path: string, gitUrl?: string, description?: string): Promise<string | null> {
  try {
    const res = await fetch(`${DDALKAK_API}/api/projects`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, path, gitUrl, description }),
    });
    if (res.ok) {
      const data = await res.json() as { id?: string };
      return data.id ?? null;
    }
  } catch {
    // ignore
  }
  return null;
}

async function registerAgent(name: string, projectId: string | null): Promise<void> {
  try {
    await fetch(`${DDALKAK_API}/api/agents`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, projectId }),
    });
  } catch {
    // ignore
  }
}

async function writeSkillsDoc(projectPath: string): Promise<void> {
  const skillsDir = join(projectPath, '.ddalkak', 'skills');
  const skillsFile = join(skillsDir, 'ddalkak.md');
  try {
    await access(skillsFile);
    // file exists, do not overwrite
  } catch {
    await writeFile(skillsFile, SKILLS_DOC, 'utf-8');
  }
}

export async function initCommand(args: string[]) {
  const projectPath = resolve(args[0] ?? '.');

  if (!existsSync(projectPath)) {
    console.error(`  Path not found: ${projectPath}`);
    process.exit(1);
  }

  console.log(`\n  ⚡ ${APP_NAME} init\n`);
  console.log(`  Project path: ${projectPath}`);

  if (await ddalkakDirExists(projectPath)) {
    console.log('  .ddalkak/ already exists. Skipping init.');
    process.exit(0);
  }

  // Detect
  const git = isGitRepo(projectPath);
  const gitUrl = git ? getGitUrl(projectPath) : undefined;
  const techStack = await detectTechStack(projectPath);

  console.log(`  Git repo: ${git ? 'yes' : 'no'}${gitUrl ? ` (${gitUrl})` : ''}`);
  console.log(`  Tech stack: ${techStack.length ? techStack.join(', ') : 'unknown'}`);

  // Create .ddalkak/
  await ensureDdalkakDir(projectPath);

  const name = projectPath.split('/').pop() ?? 'project';
  await writeConfig(projectPath, {
    name,
    gitUrl,
    techStack,
    guardrails: {
      max_files_changed: 20,
      max_execution_minutes: 30,
    },
  });

  // Write skills protocol doc
  await writeSkillsDoc(projectPath);

  console.log(`\n  Created .ddalkak/ with:`);
  console.log(`    - config.yaml`);
  console.log(`    - agents/`);
  console.log(`    - skills/`);
  console.log(`    - skills/ddalkak.md`);
  console.log(`    - hooks/`);

  // Register project and agents with server if running
  const serverUp = await isServerRunning();
  if (serverUp) {
    console.log(`\n  Registering with Ddalkak server...`);
    const projectId = await registerProject(name, projectPath, gitUrl);
    if (projectId) {
      console.log(`    - Project registered (id: ${projectId})`);
    }

    const agents = detectAgents();
    for (const agent of agents) {
      await registerAgent(agent, projectId);
      console.log(`    - Agent registered: ${agent}`);
    }
  } else {
    console.log(`\n  서버 실행 중이 아닙니다. ddalkak start 후 대시보드에서 프로젝트를 확인하세요.`);
  }

  console.log(`\n  Done! Commit .ddalkak/ to share with your team.\n`);
}
