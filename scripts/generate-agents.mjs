#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

/**
 * generate-agents.mjs
 * 에이전트 정의를 .ai-harness/agents/에 생성하고 .claude/agents/에 복사한다.
 *
 * 사용법:
 *   node scripts/generate-agents.mjs <configPath> <harnessDir> <claudeAgentsDir>
 *
 * 입력:
 *   configPath:      .ai-harness/config.yaml 경로
 *   harnessDir:      .ai-harness/ 디렉토리 경로
 *   claudeAgentsDir: .claude/agents/ 디렉토리 경로
 *
 * 출력 (JSON):
 *   { ok: true, generated: [...], skipped: [...], copied: [...] }
 */

const MANAGED_BY = 'ai-harness';

function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function parseSimpleYaml(content) {
  const result = { project: {}, teams: [], agents: {} };
  const lines = content.split('\n');
  let currentSection = null;
  let currentSubSection = null;

  for (const line of lines) {
    if (/^project:/.test(line)) { currentSection = 'project'; continue; }
    if (/^teams:/.test(line)) { currentSection = 'teams'; continue; }
    if (/^agents:/.test(line)) { currentSection = 'agents'; continue; }

    if (currentSection === 'project' && /^\s+\w+:/.test(line)) {
      const match = line.match(/^\s+(\w+):\s*(.+)?/);
      if (match) {
        let value = (match[2] || '').trim();
        if (value.startsWith('[') && value.endsWith(']')) {
          value = value.slice(1, -1).split(',').map(s => s.trim());
        }
        if (value === '""' || value === "''") value = '';
        result.project[match[1]] = value;
      }
    }

    if (currentSection === 'teams' && /^\s+-\s*/.test(line)) {
      const match = line.match(/^\s+-\s*(.+)/);
      if (match) result.teams.push(match[1].trim());
    }
  }

  return result;
}

function determineAgents(teams, projectName) {
  const agents = [];
  const hasBackend = teams.includes('backend');
  const hasFrontend = teams.includes('frontend');
  const hasPlanning = teams.includes('planning');
  const hasDesign = teams.includes('design');
  const hasDev = hasBackend || hasFrontend;

  if (hasDev) {
    agents.push({
      name: `${projectName}-developer`,
      template: 'project-developer',
      condition: 'backend/frontend',
    });
    agents.push({
      name: `${projectName}-reviewer`,
      template: 'project-reviewer',
      condition: 'backend/frontend',
    });
  }

  if (hasBackend) {
    agents.push({
      name: `${projectName}-architect`,
      template: 'project-architect',
      condition: 'backend',
    });
  }

  if (hasPlanning) {
    agents.push({
      name: `${projectName}-planner`,
      template: 'project-planner',
      condition: 'planning',
    });
  }

  if (hasDesign) {
    agents.push({
      name: `${projectName}-designer`,
      template: 'project-designer',
      condition: 'design',
    });
  }

  return agents;
}

function copyAgent(srcPath, destDir, agentName) {
  ensureDir(destDir);
  const destPath = path.join(destDir, `${agentName}.md`);

  if (fs.existsSync(destPath)) {
    const existing = fs.readFileSync(destPath, 'utf-8');
    if (existing.includes(`_managed_by: ${MANAGED_BY}`)) {
      fs.copyFileSync(srcPath, destPath);
      return { action: 'updated', path: destPath };
    }
    return { action: 'skipped', path: destPath, reason: 'exists (not managed by harness)' };
  }

  fs.copyFileSync(srcPath, destPath);
  return { action: 'copied', path: destPath };
}

// Main
const [,, configPath, harnessDir, claudeAgentsDir] = process.argv;

if (!configPath || !harnessDir || !claudeAgentsDir) {
  console.error('사용법:');
  console.error('  node scripts/generate-agents.mjs <configPath> <harnessDir> <claudeAgentsDir>');
  process.exit(1);
}

try {
  if (!fs.existsSync(configPath)) {
    console.error(`config 파일 없음: ${configPath}`);
    process.exit(1);
  }

  const configContent = fs.readFileSync(configPath, 'utf-8');
  const config = parseSimpleYaml(configContent);
  const projectName = config.project.name || 'project';
  const teams = config.teams;

  if (teams.length === 0) {
    console.log(JSON.stringify({ ok: true, generated: [], skipped: [], message: '팀이 없어 에이전트를 생성하지 않습니다.' }));
    process.exit(0);
  }

  const agentsList = determineAgents(teams, projectName);
  const agentsDir = path.join(harnessDir, 'agents');
  ensureDir(agentsDir);
  ensureDir(claudeAgentsDir);

  const generated = [];
  const skipped = [];
  const copied = [];

  for (const agent of agentsList) {
    const agentPath = path.join(agentsDir, `${agent.name}.md`);

    // .ai-harness/agents/에 이미 있으면 스킵 (Claude가 init 시 직접 Write)
    if (fs.existsSync(agentPath)) {
      // .claude/agents/로 복사/업데이트
      const result = copyAgent(agentPath, claudeAgentsDir, agent.name);
      copied.push({ name: agent.name, ...result });
    } else {
      // 에이전트 파일이 아직 없으면 생성 대상으로 표시
      generated.push({
        name: agent.name,
        template: agent.template,
        path: agentPath,
        claudePath: path.join(claudeAgentsDir, `${agent.name}.md`),
        condition: agent.condition,
      });
    }
  }

  console.log(JSON.stringify({ ok: true, projectName, teams, generated, skipped, copied }, null, 2));
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
