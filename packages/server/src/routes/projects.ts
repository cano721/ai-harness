import { Router } from 'express';
import { createDb, projects, agents, conventions } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import type { ApiResponse, Project } from '@ddalkak/shared';
import { z } from 'zod';
import { validate } from '../middleware/validation.js';
import { analyzeProject } from '../services/project-analyzer.service.js';
import { writeFile, mkdir, readFile, access } from 'fs/promises';
import { writeFileSync, unlinkSync } from 'fs';
import { join, dirname } from 'path';
import { execSync, execFile } from 'child_process';
import { fileURLToPath } from 'url';
import { tmpdir } from 'os';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

async function pathExists(p: string): Promise<boolean> {
  try { await access(p); return true; } catch { return false; }
}

function getCleanEnv(): Record<string, string | undefined> {
  const env = { ...process.env };
  // Claude Code 중첩 실행 방지 환경변수 제거
  delete env.CLAUDE_CODE_ENTRYPOINT;
  delete env.CLAUDE_CODE_SESSION;
  delete env.CLAUDE_CODE_PARENT_SESSION;
  delete env.CLAUDECODE;
  delete env.CMUX_CLAUDE_PID;
  return env;
}

interface ClaudeAnalysisResult {
  claudeMd: string;
  convention: string;
  architecture: string;
  integration: string;
  review: string;
}

async function analyzeWithClaude(projectPath: string): Promise<ClaudeAnalysisResult | null> {
  const prompt = `이 프로젝트를 분석하고 다음 5개를 JSON으로 반환해줘. 반드시 JSON만 출력하고 다른 텍스트는 없어야 해.

분석할 것:
1. 프로젝트 구조 (디렉토리, 주요 파일)
2. 기술 스택 (실제 사용 중인 프레임워크, 라이브러리)
3. 코딩 패턴 (네이밍, 스타일, 아키텍처) + 개발 절차 + 코드 예시
4. 아키텍처 구조 (도메인 목록, 모듈 역할, 레이어 관계)
5. 외부 연동 패턴 (Kafka, Feign, Redis, AWS 등)

반환 형식:
{
  "claudeMd": "CLAUDE.md 전체 내용 (마크다운). 이 프로젝트의 기술 스택, 구조, 핵심 아키텍처, 보안 규칙을 포함. CLAUDE.md는 간결하게 유지하고, 길어지는 상세 내용은 외부 파일로 분리하여 참조. 반드시 다음 참조 안내 섹션을 포함:\n## 참고 문서\n- 코드 작성 시: .ddalkak/docs/convention.md (코딩 컨벤션, 개발 가이드, 패턴)\n- 프로젝트 이해 시: .ddalkak/docs/architecture.md (구조, 도메인, 인증, 아키텍처)\n- 외부 연동 시: .ddalkak/docs/integration.md (Kafka, Feign, Redis 등)\n- 코드 리뷰 시: .ddalkak/docs/review.md (리뷰 체크리스트)",
  "convention": "convention.md 전체 내용 (마크다운). 코딩 컨벤션 + 개발 가이드를 통합한 문서. 코드 작성 시 참고하는 규칙과 패턴. 실제 코드에서 감지한 컨벤션(naming, style, structure, testing, API, 예외처리)과 개발 절차(새 도메인 추가 방법, 파일 배치 규칙), 코드 예시(Entity/DTO/Repository/테스트 작성 패턴)를 모두 포함.",
  "architecture": "architecture.md 전체 내용 (마크다운). 프로젝트 이해에 필요한 모든 것. 프로젝트 구조, 도메인 목록, 모듈 역할, 레이어 관계를 상세하게 정리. 인증/인가 패턴(JWT 흐름, MemberContext, BuilderContext, 테넌트 필터링, TenantContext, TenantInterceptor 등)과 멀티테넌시, 공통 패턴도 포함.",
  "integration": "integration.md 전체 내용 (마크다운). 외부 시스템 연동 정보만 담는다. Kafka 토픽/이벤트 패턴, Feign 클라이언트, Redis 사용, AWS 연동 등. 인증/인가 패턴은 architecture.md에 속하므로 여기에 포함하지 않는다. 외부 연동이 없으면 빈 문자열 반환.",
  "review": "review.md 전체 내용 (마크다운). 이 프로젝트의 코드를 리뷰할 때 체크할 상세 항목. 프로젝트 특화된 체크리스트."
}`;

  try {
    const promptFile = join(tmpdir(), `ddalkak-analyze-${Date.now()}.txt`);
    writeFileSync(promptFile, prompt, 'utf-8');
    try {
      const { stdout } = await execFileAsync(
        'bash',
        ['-c', `cat "${promptFile}" | claude --print --output-format text --dangerously-skip-permissions -`],
        { cwd: projectPath, encoding: 'utf-8', timeout: 300000, maxBuffer: 10 * 1024 * 1024, env: getCleanEnv() }
      );
      const jsonMatch = stdout.match(/\{[\s\S]*\}/);
      if (!jsonMatch) throw new Error('JSON not found in response');
      return JSON.parse(jsonMatch[0]) as ClaudeAnalysisResult;
    } finally {
      try { unlinkSync(promptFile); } catch {}
    }
  } catch (err) {
    console.error('[analyzeWithClaude] failed:', err instanceof Error ? err.message : String(err));
    return null;
  }
}

function buildConventionsMd(techStack: string[]): string {
  const convList = buildConventions(techStack);
  const grouped: Record<string, string[]> = {};
  for (const c of convList) {
    if (!grouped[c.category]) grouped[c.category] = [];
    grouped[c.category].push(c.rule);
  }
  return [
    '# 코딩 컨벤션',
    '',
    ...Object.entries(grouped).flatMap(([cat, rules]) => [
      `## ${cat}`,
      ...rules.map(r => `- ${r}`),
      '',
    ]),
  ].join('\n');
}

function buildClaudeMdContent(projectName: string, techStack: string[], projectPath: string): string {
  const stackLines = techStack.length > 0 ? techStack.map(s => `- ${s}`).join('\n') : '- (감지된 스택 없음)';
  const pathSummary = projectPath.split('/').slice(-3).join('/');
  return `# ${projectName}

## 기술 스택
${stackLines}

## 코딩 컨벤션
- 기존 코드 컨벤션을 먼저 파악하고 따른다
- 변경 범위를 최소화한다
- 상세 컨벤션은 .ddalkak/docs/convention.md를 참고하라

## 프로젝트 구조
- 경로: ${pathSummary}
`;
}

function buildConventions(techStack: string[]): Array<{ category: string; rule: string }> {
  const common = [
    { category: 'structure', rule: '함수는 20줄 이내로 유지한다' },
    { category: 'structure', rule: '매직넘버는 상수로 분리한다' },
  ];

  const stackLower = techStack.map(s => s.toLowerCase());
  const result = [...common];

  if (stackLower.some(s => s.includes('node') || s.includes('typescript') || s.includes('javascript') || s.includes('react') || s.includes('next'))) {
    result.push(
      { category: 'naming', rule: 'camelCase 변수명 사용' },
      { category: 'style', rule: 'async/await 사용 (callback 지양)' },
      { category: 'style', rule: 'ESM import 사용' },
    );
  }

  if (stackLower.some(s => s.includes('java') || s.includes('spring'))) {
    result.push(
      { category: 'naming', rule: 'PascalCase 클래스명 사용' },
      { category: 'style', rule: 'final 우선 사용' },
    );
  }

  if (stackLower.some(s => s.includes('python'))) {
    result.push(
      { category: 'naming', rule: 'snake_case 변수명 사용' },
      { category: 'style', rule: 'type hint 필수 작성' },
    );
  }

  return result;
}

const analyzeProjectSchema = z.object({
  path: z.string().min(1, 'path is required'),
});

const createProjectSchema = z.object({
  name: z.string().min(1, 'name is required'),
  path: z.string().optional(),
  gitUrl: z.string().optional(),
  description: z.string().optional(),
});

const updateProjectSchema = z.object({
  name: z.string().min(1).optional(),
  path: z.string().optional(),
  gitUrl: z.string().optional(),
  description: z.string().optional(),
});

export const projectsRouter = Router();

// Analyze project
projectsRouter.post('/analyze', validate(analyzeProjectSchema), async (req, res) => {
  const { path } = req.body;
  try {
    const data = await analyzeProject(path);
    res.json({ ok: true, data });
  } catch (err) {
    res.status(400).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// List all projects
projectsRouter.get('/', async (_req, res) => {
  const db = await createDb();
  const result = await db.select().from(projects);
  const response: ApiResponse<typeof result> = { ok: true, data: result };
  res.json(response);
});

// Get single project
projectsRouter.get('/:id', async (req, res) => {
  const db = await createDb();
  const [result] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!result) {
    res.status(404).json({ ok: false, error: 'Project not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

// Create project
projectsRouter.post('/', validate(createProjectSchema), async (req, res) => {
  const db = await createDb();
  const { name, path, gitUrl, description } = req.body;

  let resolvedGitUrl = gitUrl;

  if (path) {
    try {
      const analysis = await analyzeProject(path);
      if (!resolvedGitUrl && analysis.git.url) {
        resolvedGitUrl = analysis.git.url;
      }
      const [project] = await db
        .insert(projects)
        .values({ name, path, gitUrl: resolvedGitUrl, description })
        .returning();

      // Register detected CLIs as agents
      const cliMap: Array<{ key: keyof typeof analysis.installedCLIs; adapterType: string }> = [
        { key: 'claude', adapterType: 'claude_local' },
        { key: 'codex', adapterType: 'codex' },
        { key: 'cursor', adapterType: 'cursor' },
      ];
      for (const { key, adapterType } of cliMap) {
        if (analysis.installedCLIs[key]) {
          await db.insert(agents).values({
            projectId: project.id,
            name: adapterType,
            adapterType,
            config: {},
          });
        }
      }

      res.status(201).json({ ok: true, data: project });
      return;
    } catch {
      // analyzeProject failed — fall through to plain insert
    }
  }

  const [result] = await db.insert(projects).values({ name, path, gitUrl: resolvedGitUrl, description }).returning();
  res.status(201).json({ ok: true, data: result });
});

// Update project
projectsRouter.patch('/:id', validate(updateProjectSchema), async (req, res) => {
  const db = await createDb();
  const { name, path, gitUrl, description } = req.body;
  const [result] = await db
    .update(projects)
    .set({ name, path, gitUrl, description, updatedAt: new Date() })
    .where(eq(projects.id, req.params.id as string))
    .returning();
  if (!result) {
    res.status(404).json({ ok: false, error: 'Project not found' });
    return;
  }
  res.json({ ok: true, data: result });
});

// Setup: Generate CLAUDE.md
projectsRouter.post('/:id/setup/claudemd', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const claudeMdPath = join(project.path, 'CLAUDE.md');
  if (await pathExists(claudeMdPath)) {
    res.status(409).json({ ok: false, error: 'CLAUDE.md already exists' });
    return;
  }
  try {
    const analysis = await analyzeProject(project.path);
    const content = buildClaudeMdContent(project.name, analysis.techStack, project.path);
    await writeFile(claudeMdPath, content, 'utf-8');
    res.status(201).json({ ok: true, data: { path: claudeMdPath } });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Apply security hooks
projectsRouter.post('/:id/setup/hooks', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  try {
    const claudeDir = join(project.path, '.claude');
    await mkdir(claudeDir, { recursive: true });
    const settingsPath = join(claudeDir, 'settings.json');
    let settings: Record<string, unknown> = {};
    if (await pathExists(settingsPath)) {
      const raw = await readFile(settingsPath, 'utf-8');
      settings = JSON.parse(raw);
    }
    const hooksDir = join(dirname(dirname(dirname(dirname(__dirname)))), 'hooks');
    const newHooks = {
      PreToolUse: [
        {
          matcher: 'Bash',
          hooks: [
            { type: 'command', command: `bash ${join(hooksDir, 'block-dangerous.sh')}` },
            { type: 'command', command: `bash ${join(hooksDir, 'secret-scanner.sh')}` },
          ],
        },
      ],
    };
    settings.hooks = newHooks;
    await writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
    res.status(201).json({ ok: true, data: { hooksApplied: ['block-dangerous', 'secret-scanner'] } });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Generate conventions
projectsRouter.post('/:id/setup/conventions', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  try {
    const analysis = await analyzeProject(project.path);
    const convList = buildConventions(analysis.techStack);
    const { ensureDdalkakDir, writeConventions } = await import('@ddalkak/shared');
    await ensureDdalkakDir(project.path);
    const ddalkakConvs = convList.map(c => ({ category: c.category, rule: c.rule, scope: 'project' as const, enabled: true }));
    await writeConventions(project.path, ddalkakConvs);
    for (const c of convList) {
      await db.insert(conventions).values({
        projectId: project.id,
        category: c.category,
        rule: c.rule,
        scope: 'project',
        enabled: true,
      });
    }
    res.status(201).json({ ok: true, data: { conventions: convList } });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Update CLAUDE.md content
projectsRouter.patch('/:id/setup/claudemd', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const { content } = req.body;
  if (typeof content !== 'string') {
    res.status(400).json({ ok: false, error: 'content is required' });
    return;
  }
  try {
    const claudeMdPath = join(project.path, 'CLAUDE.md');
    await writeFile(claudeMdPath, content, 'utf-8');
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Delete CLAUDE.md
projectsRouter.delete('/:id/setup/claudemd', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  try {
    const { unlink } = await import('fs/promises');
    const claudeMdPath = join(project.path, 'CLAUDE.md');
    await unlink(claudeMdPath);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Replace hooks
projectsRouter.put('/:id/setup/hooks', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const { hooks } = req.body;
  if (!hooks || typeof hooks !== 'object') {
    res.status(400).json({ ok: false, error: 'hooks is required' });
    return;
  }
  try {
    const claudeDir = join(project.path, '.claude');
    await mkdir(claudeDir, { recursive: true });
    const settingsPath = join(claudeDir, 'settings.json');
    let settings: Record<string, unknown> = {};
    if (await pathExists(settingsPath)) {
      const raw = await readFile(settingsPath, 'utf-8');
      settings = JSON.parse(raw);
    }
    settings.hooks = hooks;
    await writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Delete hooks
projectsRouter.delete('/:id/setup/hooks', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  try {
    const settingsPath = join(project.path, '.claude', 'settings.json');
    if (await pathExists(settingsPath)) {
      const raw = await readFile(settingsPath, 'utf-8');
      const settings = JSON.parse(raw);
      delete settings.hooks;
      await writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
    }
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
});

// Setup: Unified wizard (SSE)
projectsRouter.get('/:id/setup', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  let closed = false;
  req.on('close', () => { closed = true; });

  const sendEvent = (event: string, data: unknown) => {
    if (!closed) {
      res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    }
  };

  let promptFile: string | null = null;

  try {
    sendEvent('status', { message: '프로젝트 분석 중...' });

    const { ensureDdalkakDir } = await import('@ddalkak/shared');
    const analysis = await analyzeProject(project.path);

    // Pre-check which files already exist
    const claudeMdPath = join(project.path, 'CLAUDE.md');
    const settingsPath = join(project.path, '.claude', 'settings.json');
    const docsDir = join(project.path, '.ddalkak', 'docs');
    const conventionPath = join(docsDir, 'convention.md');
    const architecturePath = join(docsDir, 'architecture.md');
    const integrationPath = join(docsDir, 'integration.md');
    const reviewPath = join(docsDir, 'review.md');
    const agentsDir = join(project.path, '.claude', 'agents');
    const workflowsDir = join(project.path, '.ddalkak', 'workflows');
    const developerAgentPath = join(agentsDir, 'developer.md');
    const reviewerAgentPath = join(agentsDir, 'reviewer.md');
    const implementWorkflowPath = join(workflowsDir, 'implement-feature.md');
    const fixBugWorkflowPath = join(workflowsDir, 'fix-bug.md');
    const refactorWorkflowPath = join(workflowsDir, 'refactor.md');

    const claudeMdExisted = await pathExists(claudeMdPath);
    const hooksExisted = analysis.hooks.length > 0;
    const conventionExisted = await pathExists(conventionPath) || analysis.docs.some(d => d.name === 'convention') || analysis.skills.some(s => s.name === 'convention');
    const architectureExisted = await pathExists(architecturePath);
    const integrationExisted = await pathExists(integrationPath);
    const reviewExisted = await pathExists(reviewPath);
    const developerAgentExisted = await pathExists(developerAgentPath);
    const reviewerAgentExisted = await pathExists(reviewerAgentPath);
    const implementWorkflowExisted = await pathExists(implementWorkflowPath);
    const fixBugWorkflowExisted = await pathExists(fixBugWorkflowPath);
    const refactorWorkflowExisted = await pathExists(refactorWorkflowPath);

    const filesToCreate: string[] = [];
    if (!claudeMdExisted) filesToCreate.push(`${project.path}/CLAUDE.md`);
    if (!hooksExisted) filesToCreate.push(`${project.path}/.claude/settings.json에 보안 Hook 추가`);
    if (!conventionExisted) filesToCreate.push(`${project.path}/.ddalkak/docs/convention.md`);
    if (!architectureExisted) filesToCreate.push(`${project.path}/.ddalkak/docs/architecture.md`);
    if (!integrationExisted) filesToCreate.push(`${project.path}/.ddalkak/docs/integration.md (외부 연동이 있는 경우만)`);
    if (!reviewExisted) filesToCreate.push(`${project.path}/.ddalkak/docs/review.md`);
    if (!developerAgentExisted) filesToCreate.push(`${project.path}/.claude/agents/developer.md`);
    if (!reviewerAgentExisted) filesToCreate.push(`${project.path}/.claude/agents/reviewer.md`);
    if (!implementWorkflowExisted) filesToCreate.push(`${project.path}/.ddalkak/workflows/implement-feature.md`);
    if (!fixBugWorkflowExisted) filesToCreate.push(`${project.path}/.ddalkak/workflows/fix-bug.md`);
    if (!refactorWorkflowExisted) filesToCreate.push(`${project.path}/.ddalkak/workflows/refactor.md`);

    const steps: { name: string; action: string; detail: string }[] = [];

    if (filesToCreate.length === 0) {
      // All files already exist — skip
      const checkFiles = [
        { name: 'CLAUDE.md', path: claudeMdPath },
        { name: '보안 Hook', path: settingsPath },
        { name: '컨벤션', path: conventionPath },
        { name: 'architecture', path: architecturePath },
        { name: 'integration', path: integrationPath },
        { name: 'review', path: reviewPath },
        { name: 'developer 에이전트', path: developerAgentPath },
        { name: 'reviewer 에이전트', path: reviewerAgentPath },
        { name: '기능 구현 워크플로우', path: implementWorkflowPath },
        { name: '버그 수정 워크플로우', path: fixBugWorkflowPath },
        { name: '리팩토링 워크플로우', path: refactorWorkflowPath },
      ];
      for (const f of checkFiles) {
        steps.push({ name: f.name, action: 'skipped', detail: '이미 존재함' });
      }
      sendEvent('done', { steps });
      res.end();
      return;
    }

    if (closed) { res.end(); return; }

    sendEvent('status', { message: 'Claude Code로 셋업 중...' });

    await ensureDdalkakDir(project.path);
    await mkdir(docsDir, { recursive: true });

    const hooksDir = join(dirname(dirname(dirname(dirname(__dirname)))), 'hooks');
    const prompt = `이 프로젝트를 분석하고 다음 파일들을 생성해줘:
${filesToCreate.map(f => `- ${f}`).join('\n')}

각 파일의 내용 기준:

Guard + Guide (보안, 컨벤션, 문서):
- CLAUDE.md: 간결하게. 기술 스택, 핵심 아키텍처, 보안 규칙. 상세는 .ddalkak/docs/ 참조 안내.
  반드시 다음 참조 안내 섹션을 포함:
  ## 참고 문서
  - 코드 작성 시: .ddalkak/docs/convention.md (코딩 컨벤션, 개발 가이드, 패턴)
  - 프로젝트 이해 시: .ddalkak/docs/architecture.md (구조, 도메인, 인증, 아키텍처)
  - 외부 연동 시: .ddalkak/docs/integration.md (Kafka, Feign, Redis 등)
  - 코드 리뷰 시: .ddalkak/docs/review.md (리뷰 체크리스트)

  ## 에이전트
  - 개발: .claude/agents/developer.md
  - 리뷰: .claude/agents/reviewer.md

  ## 워크플로우
  - 기능 구현: .ddalkak/workflows/implement-feature.md
  - 버그 수정: .ddalkak/workflows/fix-bug.md
  - 리팩토링: .ddalkak/workflows/refactor.md
- convention.md: 코딩 컨벤션 + 개발 가이드 통합. 실제 코드 패턴 기반.
  네이밍, 스타일, 구조, 테스트 컨벤션, Entity/DTO/Repository 작성 패턴, 코드 예시.
  코드 작성 시 참고하는 규칙과 패턴을 담는다.
- architecture.md: 프로젝트 이해에 필요한 모든 것.
  프로젝트 구조, 도메인 목록, 모듈 역할, 레이어 관계,
  인증/인가 패턴(JWT, MemberContext, 테넌트 필터링 등), 멀티테넌시, 공통 패턴.
- integration.md: 외부 시스템 연동 정보만 담는다.
  Kafka 토픽/이벤트 패턴, Feign 클라이언트, Redis 사용, AWS 연동 등.
  인증/인가 패턴은 architecture.md에 속하므로 여기에 포함하지 않는다.
  외부 연동이 없으면 생성하지 마.
- review.md: 프로젝트 특화 리뷰 체크리스트. 코드 리뷰 시 참고.
- .claude/settings.json: PreToolUse Hook에 block-dangerous.sh, secret-scanner.sh 추가.
  Hook 명령어:
  block-dangerous: bash ${join(hooksDir, 'block-dangerous.sh')}
  secret-scanner: bash ${join(hooksDir, 'secret-scanner.sh')}

Gear (에이전트, 워크플로우):
- ${project.path}/.claude/agents/developer.md: 이 프로젝트 전문 개발 에이전트. 프로젝트의 기술 스택, 패키지 구조, 코딩 패턴을 숙지하고 있는 에이전트 정의. 이 에이전트가 활성화되면 프로젝트 컨벤션을 자동으로 따르고, 적절한 위치에 파일을 생성하며, 기존 패턴을 따라 코드를 작성한다.
- ${project.path}/.claude/agents/reviewer.md: 이 프로젝트 전문 코드 리뷰 에이전트. review.md의 체크리스트를 기반으로 코드를 검증하고, 프로젝트 특화된 리뷰 피드백을 제공한다.
- ${project.path}/.ddalkak/workflows/implement-feature.md: 기능 구현 워크플로우. 이 프로젝트에서 새 기능을 구현할 때의 단계별 절차 (분석 → 설계 → 구현 → 테스트 → 리뷰). 프로젝트의 아키텍처와 패턴에 맞게 작성.
- ${project.path}/.ddalkak/workflows/fix-bug.md: 버그 수정 워크플로우. 버그 진단 → 원인 파악 → 수정 → 회귀 테스트 절차.
- ${project.path}/.ddalkak/workflows/refactor.md: 리팩토링 워크플로우. 영향 분석 → 테스트 확보 → 리팩토링 → 검증 절차.`;

    promptFile = join(tmpdir(), `ddalkak-setup-${Date.now()}.txt`);
    writeFileSync(promptFile, prompt, 'utf-8');

    try {
      await execFileAsync(
        'bash',
        ['-c', `claude --dangerously-skip-permissions --output-format text -p "$(cat '${promptFile}')" < /dev/null`],
        { cwd: project.path, encoding: 'utf-8', timeout: 300000, maxBuffer: 10 * 1024 * 1024, env: getCleanEnv() }
      );
    } catch (claudeErr) {
      // Fallback: use template-based generation
      console.error('[setup] Claude Code direct execution failed, falling back to template:', claudeErr instanceof Error ? claudeErr.message : String(claudeErr));
      const claudeAnalysis = await analyzeWithClaude(project.path);
      const usedClaude = !!claudeAnalysis;

      if (!claudeMdExisted) {
        const content = usedClaude
          ? claudeAnalysis!.claudeMd
          : buildClaudeMdContent(project.name, analysis.techStack, project.path);
        await writeFile(claudeMdPath, content, 'utf-8');
      }
      if (!hooksExisted) {
        const claudeDir = join(project.path, '.claude');
        await mkdir(claudeDir, { recursive: true });
        let settings: Record<string, unknown> = {};
        if (await pathExists(settingsPath)) {
          const raw = await readFile(settingsPath, 'utf-8');
          settings = JSON.parse(raw);
        }
        settings.hooks = {
          PreToolUse: [{
            matcher: 'Bash',
            hooks: [
              { type: 'command', command: `bash ${join(hooksDir, 'block-dangerous.sh')}` },
              { type: 'command', command: `bash ${join(hooksDir, 'secret-scanner.sh')}` },
            ],
          }],
        };
        await writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
      }
      if (!conventionExisted) {
        const convMd = usedClaude ? claudeAnalysis!.convention : buildConventionsMd(analysis.techStack);
        await writeFile(conventionPath, convMd, 'utf-8');
      }
      if (!architectureExisted) {
        const architectureMd = usedClaude && claudeAnalysis!.architecture
          ? claudeAnalysis!.architecture
          : `# 아키텍처\n\n## 프로젝트 구조\n- (프로젝트 분석 후 작성)\n\n## 도메인 목록\n- (도메인 목록 작성)\n\n## 레이어 관계\n- (레이어 관계 작성)\n`;
        await writeFile(architecturePath, architectureMd, 'utf-8');
      }
      if (!integrationExisted && usedClaude && claudeAnalysis!.integration) {
        await writeFile(integrationPath, claudeAnalysis!.integration, 'utf-8');
      }
      if (!reviewExisted) {
        const reviewMd = usedClaude ? claudeAnalysis!.review : `# 리뷰 체크리스트\n\n## 코드 품질\n- [ ] 함수/변수명이 명확한가\n- [ ] 중복 코드가 없는가\n\n## 보안\n- [ ] 시크릿/인증 정보가 하드코딩되어 있지 않은가\n\n## 테스트\n- [ ] 테스트가 작성되어 있는가\n`;
        await writeFile(reviewPath, reviewMd, 'utf-8');
      }
    }

    // Check results after Claude Code execution
    const checkFiles = [
      { name: 'CLAUDE.md', path: claudeMdPath, existed: claudeMdExisted },
      { name: '보안 Hook', path: settingsPath, existed: hooksExisted },
      { name: '컨벤션', path: conventionPath, existed: conventionExisted },
      { name: 'architecture', path: architecturePath, existed: architectureExisted },
      { name: 'integration', path: integrationPath, existed: integrationExisted },
      { name: 'review', path: reviewPath, existed: reviewExisted },
      { name: 'developer 에이전트', path: developerAgentPath, existed: developerAgentExisted },
      { name: 'reviewer 에이전트', path: reviewerAgentPath, existed: reviewerAgentExisted },
      { name: '기능 구현 워크플로우', path: implementWorkflowPath, existed: implementWorkflowExisted },
      { name: '버그 수정 워크플로우', path: fixBugWorkflowPath, existed: fixBugWorkflowExisted },
      { name: '리팩토링 워크플로우', path: refactorWorkflowPath, existed: refactorWorkflowExisted },
    ];
    for (const f of checkFiles) {
      if (f.existed) {
        steps.push({ name: f.name, action: 'skipped', detail: '이미 존재함' });
      } else if (await pathExists(f.path)) {
        steps.push({ name: f.name, action: 'created', detail: '프로젝트 분석 기반 생성' });
      } else {
        steps.push({ name: f.name, action: 'skipped', detail: '해당 없음' });
      }
    }

    sendEvent('done', { steps });
  } catch (err) {
    sendEvent('error', { message: err instanceof Error ? err.message : String(err) });
  } finally {
    if (promptFile) {
      try { unlinkSync(promptFile); } catch {}
    }
    res.end();
  }
});

// Analyze full project setup via Claude Code AI (SSE)
projectsRouter.get('/:id/analyze-setup', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  let closed = false;
  req.on('close', () => { closed = true; });

  const sendEvent = (event: string, data: unknown) => {
    if (!closed) {
      res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    }
  };

  let promptFile: string | null = null;

  try {
    // Step 1: collect files
    sendEvent('status', { message: '프로젝트 파일 수집 중...' });

    // Read CLAUDE.md
    const claudeMdPath = join(project.path, 'CLAUDE.md');
    let claudeMdContent = '(없음)';
    if (await pathExists(claudeMdPath)) {
      claudeMdContent = await readFile(claudeMdPath, 'utf-8');
    }

    // Read .claude/settings.json hooks
    let hooksContent = '(없음)';
    const settingsPath = join(project.path, '.claude', 'settings.json');
    if (await pathExists(settingsPath)) {
      const raw = await readFile(settingsPath, 'utf-8');
      try {
        const settings = JSON.parse(raw);
        if (settings.hooks) {
          hooksContent = JSON.stringify(settings.hooks, null, 2);
        }
      } catch {}
    }

    // Read .ddalkak/docs/*.md
    const docsDir = join(project.path, '.ddalkak', 'docs');
    let docsContent = '(없음)';
    if (await pathExists(docsDir)) {
      const { readdir } = await import('fs/promises');
      const files = await readdir(docsDir);
      const mdFiles = files.filter((f) => f.endsWith('.md'));
      if (mdFiles.length > 0) {
        const parts: string[] = [];
        for (const file of mdFiles) {
          const content = await readFile(join(docsDir, file), 'utf-8');
          parts.push(`--- ${file} ---\n${content}`);
        }
        docsContent = parts.join('\n\n');
      }
    }

    if (closed) { res.end(); return; }

    // Step 2: run Claude
    sendEvent('status', { message: 'Claude Code로 분석 중...' });

    const prompt = `이 프로젝트의 AI 에이전트 셋업을 Guard/Guide/Gear 관점에서 분석해줘. JSON만 반환해.

Guard (안전): Hook 설정이 적절한가, 보안 규칙이 있는가
Guide (품질): 컨벤션이 충분한가, 프로젝트 구조가 문서화되어 있는가, 빠진 패턴이 없는가
Gear (효율): 에이전트가 이 문서들만으로 효율적으로 작업할 수 있는가

좋은 패턴:
- 상세 내용을 외부 파일(.ddalkak/docs/*.md)로 분리하고 CLAUDE.md에서 참조하는 것은 좋은 패턴이다. 이것을 개선점으로 지적하지 마.

반환 형식:
{
  "score": 0-100,
  "guard": { "strengths": ["잘 된 점"], "improvements": [] },
  "guide": { "strengths": ["잘 된 점"], "improvements": [] },
  "gear": { "strengths": ["잘 된 점"], "improvements": [] },
  "summary": "한 줄 종합 요약"
}

각 파일의 역할 기준:
- convention.md: 코딩 컨벤션, 개발 가이드, 패턴. 코드 작성 시 참고.
- architecture.md: 프로젝트 구조, 도메인, 모듈, 레이어 관계 + 인증/인가 패턴(JWT, MemberContext, 테넌트 필터링 등). 인증 관련 내용이 여기에 있어야 한다.
- integration.md: 외부 시스템 연동만 (Kafka, Feign, Redis, AWS 등). 인증/인가 패턴은 architecture.md에 속함.
- review.md: 코드 리뷰 체크리스트.

improvements의 각 항목은 다음 형식:
{ "message": "개선할 점 설명", "target": "반영할 파일명 (convention.md, architecture.md, integration.md, review.md, CLAUDE.md 중 하나)", "action": "Claude Code에게 시킬 구체적 지시" }

셋업 파일 내용:
--- CLAUDE.md ---
${claudeMdContent}

--- hooks ---
${hooksContent}

--- docs ---
${docsContent}`;

    promptFile = join(tmpdir(), `ddalkak-setup-${Date.now()}.txt`);
    writeFileSync(promptFile, prompt, 'utf-8');

    const { stdout } = await execFileAsync(
      'bash',
      ['-c', `cat "${promptFile}" | claude --print --output-format text --dangerously-skip-permissions -`],
      { cwd: project.path, encoding: 'utf-8', timeout: 300000, maxBuffer: 10 * 1024 * 1024, env: getCleanEnv() }
    );

    const jsonMatch = stdout.match(/\{[\s\S]*\}/);
    if (!jsonMatch) throw new Error('JSON not found in Claude response');
    const analysis = JSON.parse(jsonMatch[0]);

    sendEvent('done', analysis);
  } catch (err) {
    sendEvent('error', { message: err instanceof Error ? err.message : String(err) });
  } finally {
    if (promptFile) {
      try { unlinkSync(promptFile); } catch {}
    }
    res.end();
  }
});

// Improve a setup file via Claude Code AI
projectsRouter.post('/:id/improve', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const { target, action } = req.body;
  if (typeof target !== 'string' || typeof action !== 'string') {
    res.status(400).json({ ok: false, error: 'target and action are required' });
    return;
  }
  if (target.includes('/') || target.includes('..')) {
    res.status(400).json({ ok: false, error: 'Invalid target' });
    return;
  }

  const filePath = target === 'CLAUDE.md'
    ? join(project.path, 'CLAUDE.md')
    : join(project.path, '.ddalkak', 'docs', target);

  try {
    const prompt = `${filePath} 파일을 읽고 수정해줘. 기존 내용을 유지하면서 다음을 추가/개선해: ${action}`;

    await execFileAsync(
      'bash',
      ['-c', `claude --dangerously-skip-permissions --output-format text -p ${JSON.stringify(prompt)} < /dev/null`],
      { cwd: project.path as string, encoding: 'utf-8', timeout: 300000, maxBuffer: 10 * 1024 * 1024, env: getCleanEnv() }
    );
    res.json({ ok: true, data: { target, updated: true } });
  } catch (err: any) {
    console.error('[improve] failed:', JSON.stringify({ message: err?.message?.slice(0, 200), stderr: err?.stderr?.slice(0, 500), stdout: err?.stdout?.slice(0, 500), code: err?.code, killed: err?.killed, signal: err?.signal }));
    const msg = err?.stderr || err?.stdout || err?.message || String(err);
    res.status(500).json({ ok: false, error: msg });
  }
});

// Improve setup files in batch via Claude Code AI
projectsRouter.post('/:id/improve-batch', async (req, res) => {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const { items } = req.body;
  if (!Array.isArray(items)) {
    res.status(400).json({ ok: false, error: 'items array is required' });
    return;
  }

  // Validate items first
  const validatedItems: Array<{ target: string; action: string }> = [];
  const invalidResults: Array<{ target: string; success: boolean }> = [];
  for (const item of items) {
    const { target, action } = item as { target: string; action: string };
    if (typeof target !== 'string' || typeof action !== 'string') {
      invalidResults.push({ target: String(target ?? ''), success: false });
      continue;
    }
    if (target.includes('/') || target.includes('..')) {
      invalidResults.push({ target, success: false });
      continue;
    }
    validatedItems.push({ target, action });
  }

  // Group by target file
  const grouped: Record<string, string[]> = {};
  for (const item of validatedItems) {
    if (!grouped[item.target]) grouped[item.target] = [];
    grouped[item.target].push(item.action);
  }

  // Execute each group in parallel
  const projectPath = project.path as string;

  const parallelResults = await Promise.all(
    Object.entries(grouped).map(async ([target, actions]) => {
      const filePath = target === 'CLAUDE.md'
        ? join(projectPath, 'CLAUDE.md')
        : join(projectPath, '.ddalkak', 'docs', target);

      try {
        const combinedAction = actions.join('\n- ');
        const prompt = `${filePath} 파일을 읽고 수정해줘. 기존 내용을 유지하면서 다음을 추가/개선해:\n- ${combinedAction}`;

        await execFileAsync(
          'bash',
          ['-c', `claude --dangerously-skip-permissions --output-format text -p ${JSON.stringify(prompt)} < /dev/null`],
          { cwd: projectPath, encoding: 'utf-8', timeout: 300000, maxBuffer: 10 * 1024 * 1024, env: getCleanEnv() }
        );
        return { target, success: true, actionsCount: actions.length };
      } catch (err: any) {
        console.error(`[improve-batch] ${target} failed:`, err?.stderr || err?.message || String(err));
        return { target, success: false, actionsCount: actions.length };
      }
    })
  );

  const results = [...invalidResults, ...parallelResults];
  res.json({ ok: true, data: { results } });
});

// Docs: Get a doc file
projectsRouter.get('/:id/docs/:name', async (req, res) => {
  const { name } = req.params;
  if (name.includes('/') || name.includes('..')) {
    res.status(400).json({ ok: false, error: 'Invalid doc name' });
    return;
  }
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const docPath = join(project.path, '.ddalkak', 'docs', `${name}.md`);
  if (!(await pathExists(docPath))) {
    res.status(404).json({ ok: false, error: 'Doc not found' });
    return;
  }
  const content = await readFile(docPath, 'utf-8');
  res.json({ ok: true, data: { name, content } });
});

// Docs: Update a doc file
projectsRouter.put('/:id/docs/:name', async (req, res) => {
  const { name } = req.params;
  if (name.includes('/') || name.includes('..')) {
    res.status(400).json({ ok: false, error: 'Invalid doc name' });
    return;
  }
  const { content } = req.body;
  if (typeof content !== 'string') {
    res.status(400).json({ ok: false, error: 'content is required' });
    return;
  }
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const docsDir = join(project.path, '.ddalkak', 'docs');
  await mkdir(docsDir, { recursive: true });
  await writeFile(join(docsDir, `${name}.md`), content, 'utf-8');
  res.json({ ok: true });
});

// Docs: Delete a doc file
projectsRouter.delete('/:id/docs/:name', async (req, res) => {
  const { name } = req.params;
  if (name.includes('/') || name.includes('..')) {
    res.status(400).json({ ok: false, error: 'Invalid doc name' });
    return;
  }
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, req.params.id as string));
  if (!project || !project.path) {
    res.status(404).json({ ok: false, error: 'Project not found or no path set' });
    return;
  }
  const docPath = join(project.path, '.ddalkak', 'docs', `${name}.md`);
  if (!(await pathExists(docPath))) {
    res.status(404).json({ ok: false, error: 'Doc not found' });
    return;
  }
  const { unlink } = await import('fs/promises');
  await unlink(docPath);
  res.json({ ok: true });
});

// Delete project
projectsRouter.delete('/:id', async (req, res) => {
  const db = await createDb();
  await db.delete(projects).where(eq(projects.id, req.params.id as string));
  res.json({ ok: true });
});
