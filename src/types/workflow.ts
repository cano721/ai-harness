export type WorkflowPhase = 'planning' | 'design' | 'development' | 'qa' | 'deploy';

export interface HandoffData {
  issue_key: string;
  current_phase: WorkflowPhase;
  history: PhaseRecord[];
}

export interface PhaseRecord {
  phase: WorkflowPhase;
  completed_at: string;
  artifacts: Record<string, string>;
  completed_by?: string;
}

export interface ApprovalGate {
  type: 'auto_pass' | 'auto_block' | 'manual';
  criteria: string;
  status: 'pending' | 'approved' | 'rejected';
  reason?: string;
}

export const PHASE_ORDER: WorkflowPhase[] = ['planning', 'design', 'development', 'qa', 'deploy'];

export const PHASE_TEAM_MAP: Record<WorkflowPhase, string> = {
  planning: 'planning',
  design: 'design',
  development: 'frontend',
  qa: 'qa',
  deploy: 'devops',
};
