import { access, mkdir, readFile, writeFile } from 'fs/promises';
import { existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { createDb, conventions, projects } from '@ddalkak/db';
import {
  ensureDdalkakDir,
  readConfig,
  writeConfig,
  writeConventions,
  type ProjectAnalysis,
  type ProjectSetupApplyResult,
  type ProjectSetupAxisStatus,
  type ProjectSetupOperation,
  type ProjectSetupPlan,
  type ProjectSetupStatus,
  type SetupAxis,
} from '@ddalkak/shared';
import { eq } from 'drizzle-orm';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = dirname(dirname(dirname(dirname(__dirname))));

const HOOK_SCRIPTS = [
  'block-dangerous.sh',
  'secret-scanner.sh',
  'check-architecture.sh',
  'guardrails-check.sh',
  'infra-change-review.sh',
] as const;

const axisLabels: Record<SetupAxis, string> = {
  guard: 'Guard',
  guide: 'Guide',
  gear: 'Gear',
};

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function readJson(path: string): Promise<Record<string, unknown> | null> {
  try {
    return JSON.parse(await readFile(path, 'utf-8')) as Record<string, unknown>;
  } catch {
    return null;
  }
}

function normalizeHookCommands(settings: Record<string, unknown> | null): string[] {
  const hooks = settings?.hooks;
  if (!hooks || typeof hooks !== 'object') {
    return [];
  }

  const commands: string[] = [];
  for (const handlers of Object.values(hooks as Record<string, unknown>)) {
    if (!Array.isArray(handlers)) {
      continue;
    }

    for (const handler of handlers) {
      if (typeof handler === 'string') {
        commands.push(handler);
        continue;
      }
      if (!handler || typeof handler !== 'object') {
        continue;
      }

      const command = (handler as Record<string, unknown>).command;
      if (typeof command === 'string') {
        commands.push(command);
      }

      const nestedHooks = (handler as Record<string, unknown>).hooks;
      if (Array.isArray(nestedHooks)) {
        for (const hook of nestedHooks) {
          if (!hook || typeof hook !== 'object') {
            continue;
          }
          const nestedCommand = (hook as Record<string, unknown>).command;
          if (typeof nestedCommand === 'string') {
            commands.push(nestedCommand);
          }
        }
      }
    }
  }

  return commands;
}

function buildConventions(techStack: string[]): Array<{ category: string; rule: string }> {
  const common = [
    { category: 'structure', rule: '함수는 20줄 이내로 유지한다' },
    { category: 'structure', rule: '매직넘버는 상수로 분리한다' },
  ];

  const stackLower = techStack.map((stack) => stack.toLowerCase());
  const result = [...common];

  if (stackLower.some((stack) => stack.includes('node') || stack.includes('typescript') || stack.includes('javascript') || stack.includes('react') || stack.includes('next'))) {
    result.push(
      { category: 'naming', rule: 'camelCase 변수명 사용' },
      { category: 'style', rule: 'async/await 사용 (callback 지양)' },
      { category: 'style', rule: 'ESM import 사용' },
    );
  }

  if (stackLower.some((stack) => stack.includes('java') || stack.includes('spring'))) {
    result.push(
      { category: 'naming', rule: 'PascalCase 클래스명 사용' },
      { category: 'style', rule: 'final 우선 사용' },
    );
  }

  if (stackLower.some((stack) => stack.includes('python'))) {
    result.push(
      { category: 'naming', rule: 'snake_case 변수명 사용' },
      { category: 'style', rule: 'type hint 필수 작성' },
    );
  }

  return result;
}

function buildClaudeMdContent(projectName: string, analysis: ProjectAnalysis, projectPath: string): string {
  const stackLines = analysis.techStack.length > 0 ? analysis.techStack.map((stack) => `- ${stack}`).join('\n') : '- (감지된 스택 없음)';
  const pathSummary = projectPath.split('/').slice(-3).join('/');

  return `# ${projectName}

## 역할
- 이 프로젝트는 Ddalkak control plane에서 관리되는 워크스페이스다.
- 상세 셋업 문서는 \`.ddalkak/\` 아래 파일을 우선 참조한다.

## 기술 스택
${stackLines}

## Guard
- 보안 Hook과 guardrail은 \`.claude/settings.json\` 과 \`.ddalkak/config.yaml\` 기준으로 유지한다.

## Guide
- 코드 작성 전 \`.ddalkak/docs/convention.md\` 를 확인한다.
- 구조 파악 시 \`.ddalkak/context-map.md\` 와 \`.ddalkak/docs/architecture.md\` 를 먼저 본다.
- 리뷰 시 \`.ddalkak/docs/review.md\` 를 기준으로 검토한다.

## Gear
- 개발 에이전트: \`.claude/agents/developer.md\`
- 리뷰 에이전트: \`.claude/agents/reviewer.md\`
- 워크플로우: \`.ddalkak/workflows/\`

## 프로젝트 구조
- 경로: ${pathSummary}
`;
}

function buildConventionDoc(techStack: string[]): string {
  const groups = new Map<string, string[]>();
  for (const rule of buildConventions(techStack)) {
    groups.set(rule.category, [...(groups.get(rule.category) ?? []), rule.rule]);
  }

  const sections = Array.from(groups.entries()).flatMap(([category, rules]) => [
    `## ${category}`,
    ...rules.map((rule) => `- ${rule}`),
    '',
  ]);

  return [
    '# Convention',
    '',
    '프로젝트 코드 작성 시 이 문서를 기본 규칙으로 사용한다.',
    '',
    ...sections,
    '## 개발 절차',
    '- 기존 패턴을 먼저 찾고 동일한 위치와 명명 규칙을 따른다.',
    '- 변경 범위를 최소화하고 테스트 가능한 단위로 자른다.',
    '- 새 파일을 만들 때는 기존 도메인 경계와 레이어를 우선 유지한다.',
    '',
  ].join('\n');
}

function buildArchitectureDoc(projectName: string, analysis: ProjectAnalysis): string {
  const stack = analysis.techStack.length > 0 ? analysis.techStack.join(', ') : '미감지';
  const docs = analysis.docs.length > 0 ? analysis.docs.map((doc) => `- ${doc.name}`).join('\n') : '- 아직 생성된 상세 문서 없음';

  return `# Architecture

## Project
- Name: ${projectName}
- Stack: ${stack}

## Structure
- 앱 진입 전 프로젝트 루트와 주요 패키지 경계를 먼저 확인한다.
- UI, server, shared, db, adapter 계층은 control plane 중심으로 분리되어야 한다.

## Current Assets
${docs}

## Working Rules
- 도메인별 책임을 유지하고 cross-layer import를 최소화한다.
- 공용 타입과 상수는 shared에 두고 런타임 구현은 adapter 계층에 둔다.
- 운영 UI는 control plane 관점에서 상태, 비용, 실행 흐름을 보여준다.
`;
}

function buildReviewDoc(): string {
  return `# Review Checklist

## Guard
- [ ] 위험 명령, 시크릿, 인프라 파괴 가능성이 없는가
- [ ] Hook과 guardrail 적용 범위가 의도와 맞는가

## Guide
- [ ] 기존 컨벤션과 파일 배치를 따르는가
- [ ] CLAUDE.md와 상세 문서 간 역할이 분리되어 있는가

## Gear
- [ ] 에이전트/워크플로우 자산이 실제 실행 흐름과 맞는가
- [ ] task, logs, cost, metrics가 추적 가능한 상태인가
`;
}

function buildContextMap(projectName: string, analysis: ProjectAnalysis): string {
  const techStack = analysis.techStack.length > 0 ? analysis.techStack.map((stack) => `- ${stack}`).join('\n') : '- stack not detected';
  const docs = analysis.docs.length > 0 ? analysis.docs.map((doc) => `- ${doc.name}`).join('\n') : '- no docs yet';

  return `# Context Map

## Project
- ${projectName}

## Stack
${techStack}

## Entry Points
- Server APIs: \`packages/server/src/routes\`
- UI pages: \`packages/ui/src/pages\`
- Shared contracts: \`packages/shared/src\`
- Database schema: \`packages/db/src/schema\`

## Existing Docs
${docs}

## Notes
- Guard / Guide / Gear setup state should stay visible in the control plane.
- Prefer updating existing patterns before introducing new abstractions.
`;
}

function buildDeveloperAgent(projectName: string): string {
  return `# ${projectName} Developer

- Follow \`.ddalkak/docs/convention.md\` before editing code.
- Use \`.ddalkak/context-map.md\` and \`.ddalkak/docs/architecture.md\` to locate the right layer.
- Prefer minimal, testable changes that match current project patterns.
`;
}

function buildReviewerAgent(projectName: string): string {
  return `# ${projectName} Reviewer

- Review against \`.ddalkak/docs/review.md\`.
- Prioritize regressions in Guard, Guide, and Gear setup coverage.
- Flag architecture leaks, missing tests, and misleading setup state first.
`;
}

function buildPreview(summary: string, content: string): ProjectSetupOperation['preview'] {
  return {
    kind: 'file',
    summary,
    excerpt: content.split('\n').slice(0, 4),
  };
}

function withDiffSummary(
  preview: NonNullable<ProjectSetupOperation['preview']>,
  diffSummary: NonNullable<ProjectSetupOperation['preview']>['diffSummary'],
): NonNullable<ProjectSetupOperation['preview']> {
  return {
    kind: preview.kind,
    summary: preview.summary,
    excerpt: preview.excerpt,
    diffSummary,
  };
}

function withComparePreview(
  preview: NonNullable<ProjectSetupOperation['preview']>,
  comparePreview: NonNullable<ProjectSetupOperation['preview']>['comparePreview'],
): NonNullable<ProjectSetupOperation['preview']> {
  return {
    kind: preview.kind,
    summary: preview.summary,
    excerpt: preview.excerpt,
    diffSummary: preview.diffSummary,
    comparePreview,
  };
}

function normalizeTextContent(content: string): string {
  return content.replace(/\r\n/g, '\n').trimEnd();
}

function countValueDelta(currentValues: string[], baselineValues: string[]) {
  const currentCounts = new Map<string, number>();
  const baselineCounts = new Map<string, number>();

  for (const value of currentValues) {
    currentCounts.set(value, (currentCounts.get(value) ?? 0) + 1);
  }
  for (const value of baselineValues) {
    baselineCounts.set(value, (baselineCounts.get(value) ?? 0) + 1);
  }

  let additions = 0;
  let removals = 0;
  const additionsSample: string[] = [];
  const removalsSample: string[] = [];
  const values = new Set([...currentCounts.keys(), ...baselineCounts.keys()]);
  for (const value of values) {
    const currentCount = currentCounts.get(value) ?? 0;
    const baselineCount = baselineCounts.get(value) ?? 0;
    if (baselineCount > currentCount) {
      const delta = baselineCount - currentCount;
      additions += delta;
      if (value.length > 0) {
        for (let index = 0; index < delta && additionsSample.length < 3; index += 1) {
          additionsSample.push(value);
        }
      }
    }
    if (currentCount > baselineCount) {
      const delta = currentCount - baselineCount;
      removals += delta;
      if (value.length > 0) {
        for (let index = 0; index < delta && removalsSample.length < 3; index += 1) {
          removalsSample.push(value);
        }
      }
    }
  }

  return { additions, removals, additionsSample, removalsSample };
}

function buildDiffSummary(
  additions: number,
  removals: number,
  missingSummary: string,
  alignedSummary: string,
  additionsSample: string[] = [],
  removalsSample: string[] = [],
): NonNullable<ProjectSetupOperation['preview']>['diffSummary'] {
  if (additions === 0 && removals === 0) {
    return { additions, removals, summary: alignedSummary, additionsSample, removalsSample };
  }

  if (removals === 0) {
    return { additions, removals, summary: missingSummary, additionsSample, removalsSample };
  }

  return {
    additions,
    removals,
    summary: `${additions} baseline line(s) to add, ${removals} custom line(s) to remove.`,
    additionsSample,
    removalsSample,
  };
}

function buildComparePreview(
  baselineValues: string[],
  currentValues: string[],
): NonNullable<ProjectSetupOperation['preview']>['comparePreview'] {
  return {
    baseline: baselineValues.slice(0, 6),
    current: currentValues.slice(0, 6),
  };
}

async function buildFileComparison(
  path: string,
  baselineContent: string,
): Promise<{
  drift: ProjectSetupOperation['drift'];
  diffSummary: NonNullable<ProjectSetupOperation['preview']>['diffSummary'];
  comparePreview: NonNullable<ProjectSetupOperation['preview']>['comparePreview'];
}> {
  const baselineLines = normalizeTextContent(baselineContent).split('\n').filter((line) => line.length > 0);
  if (!(await pathExists(path))) {
    return {
      drift: { state: 'missing', summary: 'Managed file is missing from the workspace.' },
      diffSummary: buildDiffSummary(
        baselineLines.length,
        0,
        `${baselineLines.length} baseline line(s) will be added.`,
        'No baseline drift detected.',
        baselineLines.slice(0, 3),
      ),
      comparePreview: buildComparePreview(baselineLines, []),
    };
  }

  const currentContent = await readFile(path, 'utf-8');
  const currentLines = normalizeTextContent(currentContent).split('\n').filter((line) => line.length > 0);
  const { additions, removals, additionsSample, removalsSample } = countValueDelta(currentLines, baselineLines);

  return additions === 0 && removals === 0
    ? {
        drift: { state: 'aligned', summary: 'Matches the current setup baseline.' },
        diffSummary: buildDiffSummary(additions, removals, '', 'No baseline drift detected.', additionsSample, removalsSample),
        comparePreview: buildComparePreview(baselineLines, currentLines),
      }
    : {
        drift: { state: 'drifted', summary: 'Differs from the current setup baseline.' },
        diffSummary: buildDiffSummary(additions, removals, '', 'No baseline drift detected.', additionsSample, removalsSample),
        comparePreview: buildComparePreview(baselineLines, currentLines),
      };
}

function buildWorkflow(title: string, steps: string[]): string {
  return [`# ${title}`, '', ...steps.map((step, index) => `${index + 1}. ${step}`), ''].join('\n');
}

async function collectSetupOperations(
  project: { id: string; name: string; path: string; gitUrl?: string | null; description?: string | null },
  analysis: ProjectAnalysis,
): Promise<ProjectSetupOperation[]> {
  const projectId = project.id;
  const projectPath = project.path;
  const db = await createDb();
  const dbConventions = await db.select().from(conventions).where(eq(conventions.projectId, projectId));

  const settingsPath = join(projectPath, '.claude', 'settings.json');
  const settings = await readJson(settingsPath);
  const hookCommands = normalizeHookCommands(settings);
  const missingHooks = HOOK_SCRIPTS.filter((script) => !hookCommands.some((command) => command.includes(script)));

  const contextMapPath = join(projectPath, '.ddalkak', 'context-map.md');
  const conventionDocPath = join(projectPath, '.ddalkak', 'docs', 'convention.md');
  const architectureDocPath = join(projectPath, '.ddalkak', 'docs', 'architecture.md');
  const reviewDocPath = join(projectPath, '.ddalkak', 'docs', 'review.md');
  const developerAgentPath = join(projectPath, '.claude', 'agents', 'developer.md');
  const reviewerAgentPath = join(projectPath, '.claude', 'agents', 'reviewer.md');
  const featureWorkflowPath = join(projectPath, '.ddalkak', 'workflows', 'implement-feature.md');
  const bugWorkflowPath = join(projectPath, '.ddalkak', 'workflows', 'fix-bug.md');
  const refactorWorkflowPath = join(projectPath, '.ddalkak', 'workflows', 'refactor.md');
  const claudeMdPath = join(projectPath, 'CLAUDE.md');
  const config = await readConfig(projectPath);
  const claudePreview = buildClaudeMdContent(project.name, analysis, projectPath);
  const contextMapPreview = buildContextMap(project.name, analysis);
  const conventionPreview = buildConventionDoc(analysis.techStack);
  const architecturePreview = buildArchitectureDoc(project.name, analysis);
  const reviewPreview = buildReviewDoc();
  const developerAgentPreview = buildDeveloperAgent(project.name);
  const reviewerAgentPreview = buildReviewerAgent(project.name);
  const featureWorkflowPreview = buildWorkflow('Implement Feature', ['Read the context map and convention docs.', 'Define the target layer and interface before editing.', 'Implement the change in the smallest coherent slice.', 'Validate behavior with tests or package build.', 'Request or perform review using the reviewer profile.']);
  const bugWorkflowPreview = buildWorkflow('Fix Bug', ['Reproduce the issue and confirm the failing path.', 'Locate the smallest safe fix.', 'Add or update a regression check.', 'Verify adjacent workflows are unaffected.']);
  const refactorWorkflowPreview = buildWorkflow('Refactor', ['Document the boundary being refactored.', 'Preserve behavior with tests or targeted verification.', 'Refactor in small commits or checkpoints.', 'Review for architecture leaks and runtime regressions.']);
  const conventionRules = buildConventions(analysis.techStack);
  const conventionRuleKeys = new Set(conventionRules.map((rule) => `${rule.category}:${rule.rule}`));
  const existingConventionValues = [
    ...analysis.conventions.map((rule) => `${rule.category}:${rule.rule}`),
    ...dbConventions.map((rule) => `${rule.category}:${rule.rule}`),
  ];
  const existingConventionKeys = new Set(existingConventionValues);
  const conventionDiffCounts = countValueDelta(existingConventionValues, Array.from(conventionRuleKeys));
  const conventionsDrift: ProjectSetupOperation['drift'] =
    existingConventionKeys.size === 0
      ? { state: 'missing', summary: 'Structured convention rules are missing.' }
      : existingConventionKeys.size === conventionRuleKeys.size && Array.from(conventionRuleKeys).every((key) => existingConventionKeys.has(key))
        ? { state: 'aligned', summary: 'Convention rules match the current setup baseline.' }
        : { state: 'drifted', summary: 'Convention rules differ from the generated setup baseline.' };
  const conventionsDiffSummary = existingConventionKeys.size === 0
    ? buildDiffSummary(
        conventionRuleKeys.size,
        0,
        `${conventionRuleKeys.size} generated rule(s) will be added.`,
        'No rule drift detected.',
        Array.from(conventionRuleKeys).slice(0, 3),
      )
    : buildDiffSummary(
        conventionDiffCounts.additions,
        conventionDiffCounts.removals,
        `${conventionDiffCounts.additions} generated rule(s) will be added.`,
        'No rule drift detected.',
        conventionDiffCounts.additionsSample,
        conventionDiffCounts.removalsSample,
      );
  const conventionsComparePreview = buildComparePreview(Array.from(conventionRuleKeys), existingConventionValues);

  const claudeComparison = await buildFileComparison(claudeMdPath, claudePreview);
  const contextMapComparison = await buildFileComparison(contextMapPath, contextMapPreview);
  const conventionDocComparison = await buildFileComparison(conventionDocPath, conventionPreview);
  const architectureDocComparison = await buildFileComparison(architectureDocPath, architecturePreview);
  const reviewDocComparison = await buildFileComparison(reviewDocPath, reviewPreview);
  const developerAgentComparison = await buildFileComparison(developerAgentPath, developerAgentPreview);
  const reviewerAgentComparison = await buildFileComparison(reviewerAgentPath, reviewerAgentPreview);
  const featureWorkflowComparison = await buildFileComparison(featureWorkflowPath, featureWorkflowPreview);
  const bugWorkflowComparison = await buildFileComparison(bugWorkflowPath, bugWorkflowPreview);
  const refactorWorkflowComparison = await buildFileComparison(refactorWorkflowPath, refactorWorkflowPreview);

  const operations: ProjectSetupOperation[] = [
    {
      id: 'guard-hooks',
      axis: 'guard',
      title: 'Workspace security hooks',
      description: missingHooks.length === 0 ? 'Required local hooks already connected.' : `Add ${missingHooks.length} workspace-local security hooks to .claude/settings.json.`,
      path: settingsPath,
      scope: 'project',
      status: missingHooks.length === 0 ? 'ready' : 'pending',
      preview: {
        kind: 'config',
        summary: 'Connect required local security hooks in .claude/settings.json.',
        excerpt: HOOK_SCRIPTS.map((script) => `bash hooks/${script}`),
      },
      drift: missingHooks.length === 0
        ? { state: 'aligned', summary: 'Required local security hooks are connected.' }
        : { state: 'missing', summary: `${missingHooks.length} required hook(s) are still missing.` },
    },
    {
      id: 'guard-config',
      axis: 'guard',
      title: 'Ddalkak guardrail config',
      description: config?.guardrails && Object.keys(config.guardrails).length > 0 ? 'Guardrail config already exists.' : 'Create .ddalkak/config.yaml with default guardrail settings.',
      path: join(projectPath, '.ddalkak', 'config.yaml'),
      scope: 'project',
      status: config?.guardrails && Object.keys(config.guardrails).length > 0 ? 'ready' : 'pending',
      preview: {
        kind: 'config',
        summary: 'Write default guardrails to .ddalkak/config.yaml.',
        excerpt: [
          'guardrails:',
          `  max_files_changed: ${Number(config?.guardrails?.max_files_changed ?? 20)}`,
          `  max_execution_minutes: ${Number(config?.guardrails?.max_execution_minutes ?? 30)}`,
        ],
      },
      drift: config?.guardrails && Object.keys(config.guardrails).length > 0
        ? { state: 'aligned', summary: 'Guardrail config is present.' }
        : { state: 'missing', summary: 'Guardrail config is missing.' },
    },
    {
      id: 'guide-claude',
      axis: 'guide',
      title: 'Project CLAUDE.md',
      description: analysis.claudeMd.exists ? 'CLAUDE.md already exists.' : 'Create a concise CLAUDE.md that points to setup assets.',
      path: claudeMdPath,
      scope: 'project',
      status: analysis.claudeMd.exists ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the project summary guide.', claudePreview)!, claudeComparison.diffSummary),
        claudeComparison.comparePreview,
      ),
      drift: claudeComparison.drift,
    },
    {
      id: 'guide-context-map',
      axis: 'guide',
      title: 'Context map',
      description: await pathExists(contextMapPath) ? 'Context map already exists.' : 'Create .ddalkak/context-map.md for fast project orientation.',
      path: contextMapPath,
      scope: 'project',
      status: await pathExists(contextMapPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the project map for orientation.', contextMapPreview)!, contextMapComparison.diffSummary),
        contextMapComparison.comparePreview,
      ),
      drift: contextMapComparison.drift,
    },
    {
      id: 'guide-convention-doc',
      axis: 'guide',
      title: 'Convention doc',
      description: await pathExists(conventionDocPath) ? 'Convention doc already exists.' : 'Create .ddalkak/docs/convention.md from detected stack patterns.',
      path: conventionDocPath,
      scope: 'project',
      status: await pathExists(conventionDocPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the coding convention baseline.', conventionPreview)!, conventionDocComparison.diffSummary),
        conventionDocComparison.comparePreview,
      ),
      drift: conventionDocComparison.drift,
    },
    {
      id: 'guide-architecture-doc',
      axis: 'guide',
      title: 'Architecture doc',
      description: await pathExists(architectureDocPath) ? 'Architecture doc already exists.' : 'Create .ddalkak/docs/architecture.md to describe boundaries and entry points.',
      path: architectureDocPath,
      scope: 'project',
      status: await pathExists(architectureDocPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the architecture boundary doc.', architecturePreview)!, architectureDocComparison.diffSummary),
        architectureDocComparison.comparePreview,
      ),
      drift: architectureDocComparison.drift,
    },
    {
      id: 'guide-review-doc',
      axis: 'guide',
      title: 'Review checklist',
      description: await pathExists(reviewDocPath) ? 'Review checklist already exists.' : 'Create .ddalkak/docs/review.md for project-specific code reviews.',
      path: reviewDocPath,
      scope: 'project',
      status: await pathExists(reviewDocPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the review checklist baseline.', reviewPreview)!, reviewDocComparison.diffSummary),
        reviewDocComparison.comparePreview,
      ),
      drift: reviewDocComparison.drift,
    },
    {
      id: 'guide-conventions-data',
      axis: 'guide',
      title: 'Convention rules data',
      description: analysis.conventions.length > 0 || dbConventions.length > 0 ? 'Convention rules already exist.' : 'Create structured convention rules for setup-aware tooling.',
      path: join(projectPath, '.ddalkak', 'conventions.yaml'),
      scope: 'project',
      status: analysis.conventions.length > 0 || dbConventions.length > 0 ? 'ready' : 'pending',
      preview: {
        kind: 'config',
        summary: 'Write structured convention rules for setup-aware tooling.',
        excerpt: conventionRules.slice(0, 4).map((rule) => `${rule.category}: ${rule.rule}`),
        diffSummary: conventionsDiffSummary,
        comparePreview: conventionsComparePreview,
      },
      drift: conventionsDrift,
    },
    {
      id: 'gear-developer-agent',
      axis: 'gear',
      title: 'Developer agent profile',
      description: await pathExists(developerAgentPath) ? 'Developer agent profile already exists.' : 'Create .claude/agents/developer.md.',
      path: developerAgentPath,
      scope: 'project',
      status: await pathExists(developerAgentPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the developer agent baseline.', developerAgentPreview)!, developerAgentComparison.diffSummary),
        developerAgentComparison.comparePreview,
      ),
      drift: developerAgentComparison.drift,
    },
    {
      id: 'gear-reviewer-agent',
      axis: 'gear',
      title: 'Reviewer agent profile',
      description: await pathExists(reviewerAgentPath) ? 'Reviewer agent profile already exists.' : 'Create .claude/agents/reviewer.md.',
      path: reviewerAgentPath,
      scope: 'project',
      status: await pathExists(reviewerAgentPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the reviewer agent baseline.', reviewerAgentPreview)!, reviewerAgentComparison.diffSummary),
        reviewerAgentComparison.comparePreview,
      ),
      drift: reviewerAgentComparison.drift,
    },
    {
      id: 'gear-workflow-feature',
      axis: 'gear',
      title: 'Feature workflow',
      description: await pathExists(featureWorkflowPath) ? 'Feature workflow already exists.' : 'Create .ddalkak/workflows/implement-feature.md.',
      path: featureWorkflowPath,
      scope: 'project',
      status: await pathExists(featureWorkflowPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the feature workflow baseline.', featureWorkflowPreview)!, featureWorkflowComparison.diffSummary),
        featureWorkflowComparison.comparePreview,
      ),
      drift: featureWorkflowComparison.drift,
    },
    {
      id: 'gear-workflow-bug',
      axis: 'gear',
      title: 'Bugfix workflow',
      description: await pathExists(bugWorkflowPath) ? 'Bugfix workflow already exists.' : 'Create .ddalkak/workflows/fix-bug.md.',
      path: bugWorkflowPath,
      scope: 'project',
      status: await pathExists(bugWorkflowPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the bug workflow baseline.', bugWorkflowPreview)!, bugWorkflowComparison.diffSummary),
        bugWorkflowComparison.comparePreview,
      ),
      drift: bugWorkflowComparison.drift,
    },
    {
      id: 'gear-workflow-refactor',
      axis: 'gear',
      title: 'Refactor workflow',
      description: await pathExists(refactorWorkflowPath) ? 'Refactor workflow already exists.' : 'Create .ddalkak/workflows/refactor.md.',
      path: refactorWorkflowPath,
      scope: 'project',
      status: await pathExists(refactorWorkflowPath) ? 'ready' : 'pending',
      preview: withComparePreview(
        withDiffSummary(buildPreview('Create the refactor workflow baseline.', refactorWorkflowPreview)!, refactorWorkflowComparison.diffSummary),
        refactorWorkflowComparison.comparePreview,
      ),
      drift: refactorWorkflowComparison.drift,
    },
  ];

  return operations;
}

function summarizeAxis(axis: SetupAxis, operations: ProjectSetupOperation[], analysis: ProjectAnalysis): string {
  const pending = operations.filter((operation) => operation.status === 'pending').length;
  if (pending === 0) {
    if (axis === 'gear' && !analysis.installedCLIs.claude && !analysis.installedCLIs.codex && !analysis.installedCLIs.cursor) {
      return 'Project assets are ready, but no local runtime CLI is currently detected.';
    }
    return `${axisLabels[axis]} assets are ready for this workspace.`;
  }

  if (axis === 'guard') {
    return 'Connect workspace-local hooks and guardrail config before running agents here.';
  }
  if (axis === 'guide') {
    return 'Document the project contract so agents can navigate and code consistently.';
  }
  return 'Create project-scoped agents and workflows to make execution repeatable.';
}

function buildAxisStatuses(operations: ProjectSetupOperation[], analysis: ProjectAnalysis): ProjectSetupAxisStatus[] {
  return (['guard', 'guide', 'gear'] as const).map((axis) => {
    const axisOperations = operations.filter((operation) => operation.axis === axis);
    const readyCount = axisOperations.filter((operation) => operation.status === 'ready').length;
    const readiness = axisOperations.length === 0 ? 100 : Math.round((readyCount / axisOperations.length) * 100);

    return {
      axis,
      label: axisLabels[axis],
      ready: axisOperations.every((operation) => operation.status === 'ready'),
      readiness,
      summary: summarizeAxis(axis, axisOperations, analysis),
      operations: axisOperations,
    };
  });
}

function filterAxisStatuses(
  axes: ProjectSetupAxisStatus[],
  requestedAxes?: SetupAxis[],
  requestedOperationIds?: string[],
): ProjectSetupAxisStatus[] {
  const axisFilter = requestedAxes && requestedAxes.length > 0 ? new Set(requestedAxes) : null;
  const operationFilter = requestedOperationIds && requestedOperationIds.length > 0 ? new Set(requestedOperationIds) : null;

  return axes
    .filter((axis) => !axisFilter || axisFilter.has(axis.axis))
    .map((axis) => {
      const operations = operationFilter
        ? axis.operations.filter((operation) => operationFilter.has(operation.id))
        : axis.operations;
      const readyCount = operations.filter((operation) => operation.status === 'ready').length;
      const readiness = operations.length === 0 ? 100 : Math.round((readyCount / operations.length) * 100);

      return {
        ...axis,
        operations,
        ready: operations.length > 0 && operations.every((operation) => operation.status === 'ready'),
        readiness,
      };
    })
    .filter((axis) => axis.operations.length > 0);
}

export async function getProjectSetupStatus(projectId: string, analysis: ProjectAnalysis): Promise<ProjectSetupStatus> {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, projectId));
  if (!project?.path) {
    throw new Error('Project not found or no path set');
  }

  const operations = await collectSetupOperations({
    id: project.id,
    name: project.name,
    path: project.path,
    gitUrl: project.gitUrl,
    description: project.description,
  }, analysis);
  const axes = buildAxisStatuses(operations, analysis);
  const ready = axes.every((axis) => axis.ready);

  return {
    projectId,
    ready,
    mode: 'workspace',
    axes,
    summary: ready
      ? 'Guard, Guide, Gear are ready for this project.'
      : 'This project still has setup gaps before it behaves like a fully prepared control-plane workspace.',
  };
}

export async function getProjectSetupPlan(
  projectId: string,
  analysis: ProjectAnalysis,
  requestedAxes?: SetupAxis[],
  requestedOperationIds?: string[],
): Promise<ProjectSetupPlan> {
  const status = await getProjectSetupStatus(projectId, analysis);
  const axes = filterAxisStatuses(status.axes, requestedAxes, requestedOperationIds);

  const allOperations = axes.flatMap((axis) => axis.operations);
  const ready = allOperations.filter((operation) => operation.status === 'ready').length;
  const pending = allOperations.filter((operation) => operation.status === 'pending').length;

  return {
    projectId,
    axes,
    totals: { ready, pending },
    summary: pending === 0
      ? 'Selected setup items are already prepared. Applying again will mostly be a no-op.'
      : requestedOperationIds && requestedOperationIds.length > 0
        ? `${pending} setup item(s) will be created or updated for the selected operation set.`
        : `${pending} setup item(s) will be created or updated across ${axes.length} axis(es).`,
  };
}

function addResult(
  results: ProjectSetupApplyResult['results'],
  axis: SetupAxis,
  operation: ProjectSetupOperation,
  outcome: 'created' | 'updated' | 'skipped' | 'error',
  detail: string,
): void {
  results.push({
    id: operation.id,
    axis,
    title: operation.title,
    outcome,
    detail,
    path: operation.path,
  });
}

async function ensureProjectHooks(projectPath: string): Promise<'created' | 'updated'> {
  const settingsPath = join(projectPath, '.claude', 'settings.json');
  await mkdir(dirname(settingsPath), { recursive: true });
  const settings = (await readJson(settingsPath)) ?? {};
  const existingHookCommands = normalizeHookCommands(settings);
  const hookDefinitions = HOOK_SCRIPTS.map((script) => ({
    type: 'command',
    command: `bash ${join(repoRoot, 'hooks', script)}`,
  }));

  const preToolUse = [
    {
      matcher: 'Bash',
      hooks: hookDefinitions,
    },
  ];

  const merged = { ...settings, hooks: { ...(settings.hooks as Record<string, unknown> | undefined), PreToolUse: preToolUse } };
  await writeFile(settingsPath, JSON.stringify(merged, null, 2) + '\n', 'utf-8');

  return existingHookCommands.length === 0 ? 'created' : 'updated';
}

export async function applyProjectSetup(
  projectId: string,
  analysis: ProjectAnalysis,
  requestedAxes?: SetupAxis[],
  options?: { force?: boolean; operationIds?: string[] },
): Promise<ProjectSetupApplyResult> {
  const db = await createDb();
  const [project] = await db.select().from(projects).where(eq(projects.id, projectId));
  if (!project?.path) {
    throw new Error('Project not found or no path set');
  }

  const plan = await getProjectSetupPlan(projectId, analysis, requestedAxes, options?.operationIds);
  const selectedAxes = plan.axes.map((axis) => axis.axis);
  const results: ProjectSetupApplyResult['results'] = [];
  const allOperations = plan.axes.flatMap((axis) => axis.operations);
  const operationMap = new Map(allOperations.map((operation) => [operation.id, operation]));
  const existingConfig = await readConfig(project.path);
  const force = options?.force === true;

  await ensureDdalkakDir(project.path);
  await mkdir(join(project.path, '.ddalkak', 'docs'), { recursive: true });
  await mkdir(join(project.path, '.ddalkak', 'workflows'), { recursive: true });
  await mkdir(join(project.path, '.claude', 'agents'), { recursive: true });

  if (selectedAxes.includes('guard')) {
    const hooksOperation = operationMap.get('guard-hooks');
    const configOperation = operationMap.get('guard-config');

    if (hooksOperation) {
      try {
        const outcome = await ensureProjectHooks(project.path);
        addResult(results, 'guard', hooksOperation, outcome, outcome === 'created' ? 'Workspace hooks were created.' : 'Workspace hooks were updated.');
      } catch (error) {
        addResult(results, 'guard', hooksOperation, 'error', error instanceof Error ? error.message : String(error));
      }
    }

    if (configOperation) {
      try {
        await writeConfig(project.path, {
          name: project.name,
          description: project.description ?? undefined,
          gitUrl: project.gitUrl ?? undefined,
          techStack: analysis.techStack,
          guardrails: {
            max_files_changed: Number(existingConfig?.guardrails?.max_files_changed ?? 20),
            max_execution_minutes: Number(existingConfig?.guardrails?.max_execution_minutes ?? 30),
          },
        });
        addResult(results, 'guard', configOperation, existingConfig ? 'updated' : 'created', existingConfig ? 'Guardrail config was updated.' : 'Guardrail config was created.');
      } catch (error) {
        addResult(results, 'guard', configOperation, 'error', error instanceof Error ? error.message : String(error));
      }
    }
  }

  if (selectedAxes.includes('guide')) {
    const docWrites: Array<[string, string, string, () => string]> = [
      ['guide-claude', join(project.path, 'CLAUDE.md'), 'Project CLAUDE.md', () => buildClaudeMdContent(project.name, analysis, project.path as string)],
      ['guide-context-map', join(project.path, '.ddalkak', 'context-map.md'), 'Context map', () => buildContextMap(project.name, analysis)],
      ['guide-convention-doc', join(project.path, '.ddalkak', 'docs', 'convention.md'), 'Convention doc', () => buildConventionDoc(analysis.techStack)],
      ['guide-architecture-doc', join(project.path, '.ddalkak', 'docs', 'architecture.md'), 'Architecture doc', () => buildArchitectureDoc(project.name, analysis)],
      ['guide-review-doc', join(project.path, '.ddalkak', 'docs', 'review.md'), 'Review checklist', buildReviewDoc],
    ];

    for (const [operationId, filePath, , buildContent] of docWrites) {
      const operation = operationMap.get(operationId);
      if (!operation) {
        continue;
      }

      try {
        const existed = await pathExists(filePath);
        if (!existed || force) {
          await writeFile(filePath, buildContent(), 'utf-8');
          addResult(results, 'guide', operation, existed ? 'updated' : 'created', existed ? `${operation.title} was reset to the setup baseline.` : `${operation.title} was created.`);
        } else {
          addResult(results, 'guide', operation, 'skipped', `${operation.title} already existed.`);
        }
      } catch (error) {
        addResult(results, 'guide', operation, 'error', error instanceof Error ? error.message : String(error));
      }
    }

    const dataOperation = operationMap.get('guide-conventions-data');
    if (dataOperation) {
      try {
        const conventionRules = buildConventions(analysis.techStack);
        await writeConventions(project.path, conventionRules.map((rule) => ({
          category: rule.category,
          rule: rule.rule,
          scope: 'project',
          enabled: true,
        })));

        const existing = await db.select().from(conventions).where(eq(conventions.projectId, project.id));
        const existingKeys = new Set(existing.map((rule) => `${rule.category}:${rule.rule}`));
        const missing = conventionRules.filter((rule) => !existingKeys.has(`${rule.category}:${rule.rule}`));
        for (const rule of missing) {
          await db.insert(conventions).values({
            projectId: project.id,
            category: rule.category,
            rule: rule.rule,
            scope: 'project',
            enabled: true,
          });
        }

        addResult(results, 'guide', dataOperation, existing.length > 0 ? 'updated' : 'created', missing.length > 0 ? `${missing.length} convention rule(s) were added.` : 'Convention rules already matched the generated set.');
      } catch (error) {
        addResult(results, 'guide', dataOperation, 'error', error instanceof Error ? error.message : String(error));
      }
    }
  }

  if (selectedAxes.includes('gear')) {
    const fileWrites: Array<[string, string, () => string]> = [
      ['gear-developer-agent', join(project.path, '.claude', 'agents', 'developer.md'), () => buildDeveloperAgent(project.name)],
      ['gear-reviewer-agent', join(project.path, '.claude', 'agents', 'reviewer.md'), () => buildReviewerAgent(project.name)],
      ['gear-workflow-feature', join(project.path, '.ddalkak', 'workflows', 'implement-feature.md'), () => buildWorkflow('Implement Feature', ['Read the context map and convention docs.', 'Define the target layer and interface before editing.', 'Implement the change in the smallest coherent slice.', 'Validate behavior with tests or package build.', 'Request or perform review using the reviewer profile.'])],
      ['gear-workflow-bug', join(project.path, '.ddalkak', 'workflows', 'fix-bug.md'), () => buildWorkflow('Fix Bug', ['Reproduce the issue and confirm the failing path.', 'Locate the smallest safe fix.', 'Add or update a regression check.', 'Verify adjacent workflows are unaffected.'])],
      ['gear-workflow-refactor', join(project.path, '.ddalkak', 'workflows', 'refactor.md'), () => buildWorkflow('Refactor', ['Document the boundary being refactored.', 'Preserve behavior with tests or targeted verification.', 'Refactor in small commits or checkpoints.', 'Review for architecture leaks and runtime regressions.'])],
    ];

    for (const [operationId, filePath, buildContent] of fileWrites) {
      const operation = operationMap.get(operationId);
      if (!operation) {
        continue;
      }

      try {
        const existed = await pathExists(filePath);
        if (!existed || force) {
          await writeFile(filePath, buildContent(), 'utf-8');
          addResult(results, 'gear', operation, existed ? 'updated' : 'created', existed ? `${operation.title} was reset to the setup baseline.` : `${operation.title} was created.`);
        } else {
          addResult(results, 'gear', operation, 'skipped', `${operation.title} already existed.`);
        }
      } catch (error) {
        addResult(results, 'gear', operation, 'error', error instanceof Error ? error.message : String(error));
      }
    }
  }

  for (const operation of allOperations) {
    if (results.some((result) => result.id === operation.id)) {
      continue;
    }
    addResult(results, operation.axis, operation, 'skipped', 'Axis was not selected for apply.');
  }

  return {
    projectId,
    appliedAxes: selectedAxes,
    results,
  };
}
