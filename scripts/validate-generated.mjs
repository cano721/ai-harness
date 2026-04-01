#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

/**
 * validate-generated.mjs
 * 생성된 에이전트/스킬/워크플로우 파일을 검증한다.
 *
 * 사용법:
 *   node scripts/validate-generated.mjs <harnessDir> [claudeAgentsDir]
 *
 * 검증 항목:
 *   1. frontmatter 필수 필드 (name, description)
 *   2. 에이전트 파일 < 300줄
 *   3. 스킬 파일 < 500줄
 *   4. Claude Code 미지원 frontmatter 필드 없음
 *   5. .claude/agents/와 .ai-harness/agents/ 동기화
 *
 * 출력 (JSON):
 *   { ok: true/false, checks: [...], errors: [...], warnings: [...] }
 */

function countLines(filePath) {
  return fs.readFileSync(filePath, 'utf-8').split('\n').length;
}

function hasFrontmatter(content) {
  return content.startsWith('---');
}

function extractFrontmatter(content) {
  if (!hasFrontmatter(content)) return {};
  const end = content.indexOf('---', 3);
  if (end === -1) return {};
  const fm = content.slice(3, end).trim();
  const result = {};
  for (const line of fm.split('\n')) {
    const match = line.match(/^(\w+):\s*(.+)/);
    if (match) result[match[1]] = match[2].trim().replace(/^["']|["']$/g, '');
  }
  return result;
}

function validateFile(filePath, type) {
  const issues = [];

  if (!fs.existsSync(filePath)) {
    return [{ level: 'error', file: filePath, message: '파일이 존재하지 않음' }];
  }

  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = countLines(filePath);
  const fm = extractFrontmatter(content);

  // frontmatter 존재 확인
  if (!hasFrontmatter(content)) {
    issues.push({ level: 'error', file: filePath, message: 'frontmatter가 없음 (---로 시작해야 함)' });
  }

  // name 필수
  if (!fm.name) {
    issues.push({ level: 'error', file: filePath, message: 'frontmatter에 name 필드가 없음' });
  }

  // description 필수
  if (!fm.description) {
    issues.push({ level: 'error', file: filePath, message: 'frontmatter에 description 필드가 없음' });
  }

  const unsupportedFields = ['_managed_by', 'sandbox_mode', 'nickname_candidates'];
  for (const field of unsupportedFields) {
    if (new RegExp(`^${field}:`, 'm').test(content)) {
      issues.push({
        level: 'warning',
        file: filePath,
        message: `Claude Code subagent frontmatter 미지원 필드가 남아 있음: ${field}`,
      });
    }
  }

  // 크기 제한
  const maxLines = type === 'agent' ? 300 : 500;
  if (lines > maxLines) {
    issues.push({
      level: 'warning',
      file: filePath,
      message: `${lines}줄 — ${type} 파일은 ${maxLines}줄 이내 권장. Progressive Disclosure(references/) 적용 고려`,
    });
  }

  return issues;
}

function validateSync(harnessAgentsDir, claudeAgentsDir) {
  const issues = [];

  if (!fs.existsSync(harnessAgentsDir) || !fs.existsSync(claudeAgentsDir)) {
    return issues;
  }

  const harnessFiles = fs.readdirSync(harnessAgentsDir).filter(f => f.endsWith('.md'));

  for (const file of harnessFiles) {
    const harnessPath = path.join(harnessAgentsDir, file);
    const claudePath = path.join(claudeAgentsDir, file);

    if (!fs.existsSync(claudePath)) {
      issues.push({
        level: 'warning',
        file: harnessPath,
        message: `.claude/agents/${file}에 복사되지 않음 — Claude Code가 인식하지 못할 수 있음`,
      });
    } else {
      const hContent = fs.readFileSync(harnessPath, 'utf-8');
      const cContent = fs.readFileSync(claudePath, 'utf-8');
      if (hContent !== cContent) {
        issues.push({
          level: 'warning',
          file: claudePath,
          message: `.ai-harness/agents/${file}와 내용이 다름 — 동기화 필요`,
        });
      }
    }
  }

  return issues;
}

// Main
const [,, harnessDir, claudeAgentsDir] = process.argv;

if (!harnessDir) {
  console.error('사용법:');
  console.error('  node scripts/validate-generated.mjs <harnessDir> [claudeAgentsDir]');
  process.exit(1);
}

try {
  const allIssues = [];
  const checks = [];

  // 에이전트 검증
  const agentsDir = path.join(harnessDir, 'agents');
  if (fs.existsSync(agentsDir)) {
    const agentFiles = fs.readdirSync(agentsDir).filter(f => f.endsWith('.md'));
    checks.push({ type: 'agents', count: agentFiles.length });
    for (const file of agentFiles) {
      allIssues.push(...validateFile(path.join(agentsDir, file), 'agent'));
    }
  }

  // 워크플로우 검증
  const workflowPath = path.join(harnessDir, 'workflow.md');
  if (fs.existsSync(workflowPath)) {
    checks.push({ type: 'workflow', exists: true });
    // 워크플로우는 frontmatter 불필요, 크기만 확인
    const lines = countLines(workflowPath);
    if (lines > 200) {
      allIssues.push({
        level: 'warning',
        file: workflowPath,
        message: `워크플로우가 ${lines}줄 — 200줄 이내 권장`,
      });
    }
  }

  // 스킬 검증 (teams 하위)
  const teamsDir = path.join(harnessDir, 'teams');
  if (fs.existsSync(teamsDir)) {
    for (const team of fs.readdirSync(teamsDir)) {
      const skillsDir = path.join(teamsDir, team, 'skills');
      if (!fs.existsSync(skillsDir)) continue;
      const skillFiles = fs.readdirSync(skillsDir).filter(f => f.endsWith('.md'));
      checks.push({ type: 'skills', team, count: skillFiles.length });
      for (const file of skillFiles) {
        allIssues.push(...validateFile(path.join(skillsDir, file), 'skill'));
      }
    }
  }

  // 동기화 검증
  if (claudeAgentsDir) {
    allIssues.push(...validateSync(agentsDir, claudeAgentsDir));
  }

  const errors = allIssues.filter(i => i.level === 'error');
  const warnings = allIssues.filter(i => i.level === 'warning');
  const ok = errors.length === 0;

  console.log(JSON.stringify({ ok, checks, errors, warnings }, null, 2));
  process.exit(ok ? 0 : 1);
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
