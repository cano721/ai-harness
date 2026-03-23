import { readFile, writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { parse, stringify } from 'yaml';
import {
  WorkflowPhase,
  HandoffData,
  PhaseRecord,
  ApprovalGate,
  PHASE_ORDER,
} from '../types/workflow.js';

const REQUIRED_ARTIFACTS: Record<WorkflowPhase, string[][]> = {
  planning: [['prd_url', 'jira_key']],
  design: [['figma_url']],
  development: [['pr_url', 'branch']],
  qa: [['test_report_url']],
  deploy: [['deploy_url']],
};

export async function loadHandoff(
  handoffsDir: string,
  issueKey: string,
): Promise<HandoffData | null> {
  const filePath = join(handoffsDir, `${issueKey}.yaml`);
  if (!existsSync(filePath)) return null;
  const raw = await readFile(filePath, 'utf-8');
  return parse(raw) as HandoffData;
}

export async function saveHandoff(handoffsDir: string, data: HandoffData): Promise<void> {
  if (!existsSync(handoffsDir)) {
    await mkdir(handoffsDir, { recursive: true });
  }
  const filePath = join(handoffsDir, `${data.issue_key}.yaml`);
  await writeFile(filePath, stringify(data), 'utf-8');
}

export function createHandoff(
  issueKey: string,
  phase: WorkflowPhase,
  artifacts: Record<string, string>,
): HandoffData {
  return {
    issue_key: issueKey,
    current_phase: phase,
    history: [
      {
        phase,
        completed_at: new Date().toISOString(),
        artifacts,
      },
    ],
  };
}

export function advancePhase(
  data: HandoffData,
  artifacts: Record<string, string>,
): HandoffData {
  const next = getNextPhase(data.current_phase);
  if (!next) {
    throw new Error(`'${data.current_phase}'은(는) 마지막 단계입니다.`);
  }

  const record: PhaseRecord = {
    phase: data.current_phase,
    completed_at: new Date().toISOString(),
    artifacts,
  };

  return {
    ...data,
    current_phase: next,
    history: [...data.history, record],
  };
}

export function getNextPhase(current: WorkflowPhase): WorkflowPhase | null {
  const idx = PHASE_ORDER.indexOf(current);
  if (idx === -1 || idx === PHASE_ORDER.length - 1) return null;
  return PHASE_ORDER[idx + 1];
}

export function validateArtifacts(
  phase: WorkflowPhase,
  artifacts: Record<string, string>,
): ApprovalGate {
  const groups = REQUIRED_ARTIFACTS[phase];

  for (const group of groups) {
    const hasAny = group.some((key) => artifacts[key] && artifacts[key].trim().length > 0);
    if (!hasAny) {
      return {
        type: 'auto_block',
        criteria: `${phase} 단계 필수 산출물: ${group.join(' 또는 ')}`,
        status: 'rejected',
        reason: `필수 산출물이 없습니다: ${group.join(', ')} 중 하나가 필요합니다.`,
      };
    }
  }

  return {
    type: 'auto_pass',
    criteria: `${phase} 단계 필수 산출물 검증 통과`,
    status: 'approved',
  };
}
