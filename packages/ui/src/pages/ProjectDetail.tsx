import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useParams, useNavigate } from 'react-router-dom';
import { useState, useRef, useEffect } from 'react';
import { api } from '../api/client.js';

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface ScoreDetail {
  label: string;
  done: boolean;
}

interface AxisScore {
  score: number;
  details: ScoreDetail[];
}

interface ProjectAnalysis {
  techStack: string[];
  git: { isRepo: boolean; url?: string; branch?: string };
  claudeMd: { exists: boolean; content?: string };
  agents: { name: string; path: string }[];
  hooks: { event: string; commands: string[] }[];
  mcpServers: { name: string; command: string; args?: string[] }[];
  docs: { name: string; path: string }[];
  skills: { name: string; path: string }[];
  workflows: { name: string; path: string }[];
  conventions: { category: string; rule: string }[];
  guardrails: Record<string, string | number>;
  installedCLIs: { claude: boolean; codex: boolean; cursor: boolean };
  scores?: {
    guard: AxisScore;
    guide: AxisScore;
    gear: AxisScore;
  };
}

interface Project {
  id: string;
  name: string;
  path?: string;
  gitUrl?: string;
  description?: string;
  createdAt: string;
}

interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: string;
  status: string;
}

interface Task {
  id: string;
  projectId: string;
  title: string;
  status: string;
  createdAt: string;
}

interface CostByProject {
  projectId: string;
  projectName: string;
  totalUsd: number;
  tokensIn: number;
  tokensOut: number;
}

interface Relation {
  id: string;
  type: string;
  sourceProject: { id: string; name: string };
  targetProject: { id: string; name: string };
}

interface ActivityEvent {
  id: string;
  projectId: string;
  eventType: string;
  detail: string;
  createdAt: string;
}

interface SetupStep {
  name: string;
  action: 'created' | 'skipped' | 'error';
  detail: string;
}

interface TaskRun {
  id: string;
  taskId: string;
  status: string;
}

// ─── Constants ────────────────────────────────────────────────────────────────

const statusStyle: Record<string, { bg: string; color: string }> = {
  todo: { bg: 'var(--surface3)', color: 'var(--text2)' },
  in_progress: { bg: 'rgba(116,185,255,0.1)', color: 'var(--blue)' },
  done: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  blocked: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

const agentStatusColors: Record<string, { bg: string; color: string }> = {
  running: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  idle: { bg: 'var(--surface3)', color: 'var(--text2)' },
  error: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

const adapterIcons: Record<string, { icon: string; color: string }> = {
  claude_local: { icon: 'C', color: '#d4a574' },
  codex_local: { icon: 'X', color: '#74b9ff' },
  cursor_local: { icon: 'Cu', color: '#a29bfe' },
};

// ─── Utility Functions ────────────────────────────────────────────────────────

function formatUsd(n: number) {
  return `$${n.toFixed(4)}`;
}

function formatTokens(n: number) {
  return n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(0)}K` : String(n);
}

function relativeTime(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return '방금';
  if (mins < 60) return `${mins}분 전`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}시간 전`;
  const days = Math.floor(hours / 24);
  return `${days}일 전`;
}

// ─── Shared Components ────────────────────────────────────────────────────────

function InfoRow({ label, value }: { label: string; value?: string }) {
  if (!value) return null;
  return (
    <div style={{ display: 'flex', gap: 12, padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
      <span style={{ fontSize: 12, color: 'var(--text2)', width: 90, flexShrink: 0 }}>{label}</span>
      <span style={{ fontSize: 12, color: 'var(--text)', wordBreak: 'break-all' }}>{value}</span>
    </div>
  );
}

function SectionCard({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, overflow: 'hidden' }}>
      <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
        {title}
      </div>
      <div style={{ padding: '12px 18px' }}>{children}</div>
    </div>
  );
}

function Badge({ children, color = 'blue' }: { children: React.ReactNode; color?: 'blue' | 'green' | 'gray' | 'yellow' | 'orange' | 'red' }) {
  const colorMap = {
    blue: { bg: 'rgba(116,185,255,0.15)', color: 'var(--blue)' },
    green: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
    gray: { bg: 'var(--surface3)', color: 'var(--text2)' },
    yellow: { bg: 'rgba(253,203,110,0.15)', color: 'var(--yellow)' },
    orange: { bg: 'rgba(253,150,60,0.15)', color: '#fd963c' },
    red: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
  };
  const s = colorMap[color];
  return (
    <span
      style={{
        padding: '2px 8px',
        borderRadius: 6,
        fontSize: 11,
        fontWeight: 600,
        background: s.bg,
        color: s.color,
        display: 'inline-block',
      }}
    >
      {children}
    </span>
  );
}

function SkeletonBlock({ width = '100%', height = 16 }: { width?: string | number; height?: number }) {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: 6,
        background: 'var(--surface3)',
        animation: 'pulse 1.5s ease-in-out infinite',
      }}
    />
  );
}

function GuidanceModal({ title, content, onClose }: { title: string; content: string; onClose: () => void }) {
  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.6)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 100,
      }}
      onClick={onClose}
    >
      <div
        style={{
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 16,
          padding: 24,
          width: 480,
          maxWidth: '90vw',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 16 }}>{title}</h3>
        <pre
          style={{
            fontSize: 12,
            color: 'var(--text)',
            background: 'var(--surface2)',
            border: '1px solid var(--border)',
            borderRadius: 8,
            padding: 14,
            overflowX: 'auto',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-all',
          }}
        >
          {content}
        </pre>
        <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 16 }}>
          <button
            onClick={onClose}
            style={{
              padding: '7px 16px',
              borderRadius: 8,
              border: '1px solid var(--border)',
              background: 'var(--surface2)',
              color: 'var(--text)',
              fontSize: 12,
              cursor: 'pointer',
            }}
          >
            닫기
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Feature 1: Guard/Guide/Gear Score Panel ──────────────────────────────────

const axisConfig = {
  guard: { label: 'Guard', fill: 'var(--green)', textColor: '#00cec9' },
  guide: { label: 'Guide', fill: 'var(--blue)', textColor: '#74b9ff' },
  gear: { label: 'Gear', fill: '#fd963c', textColor: '#fd963c' },
} as const;

function ScorePanel({ scores }: { scores: ProjectAnalysis['scores'] }) {
  if (!scores) return null;

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
        padding: '12px 14px',
        background: 'var(--surface2)',
        borderRadius: 10,
        border: '1px solid var(--border)',
        marginBottom: 14,
      }}
    >
      {(['guard', 'guide', 'gear'] as const).map((axis) => {
        const cfg = axisConfig[axis];
        const { score, details } = scores[axis];
        return (
          <div key={axis}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <span style={{ fontSize: 12, fontWeight: 600, color: cfg.textColor, width: 40 }}>{cfg.label}</span>
              <span style={{ fontSize: 11, color: 'var(--text2)', width: 36 }}>{score}%</span>
              <div
                style={{
                  flex: 1,
                  height: 8,
                  background: 'var(--surface3)',
                  borderRadius: 4,
                  overflow: 'hidden',
                }}
              >
                <div
                  style={{
                    width: `${score}%`,
                    height: '100%',
                    background: cfg.fill,
                    borderRadius: 4,
                    transition: 'width 0.4s ease',
                  }}
                />
              </div>
            </div>
            <div style={{ paddingLeft: 84, fontSize: 11, color: 'var(--text2)' }}>
              {details.map((d) => (
                <span key={d.label} style={{ marginRight: 10 }}>
                  {d.done ? '✓' : '✗'} {d.label}
                </span>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ─── Feature 2: Guard Status Section ─────────────────────────────────────────

function GuardSection({ projectId, guardScore }: { projectId: string; guardScore?: number }) {
  const { data: activity = [] } = useQuery({
    queryKey: ['activity', projectId],
    queryFn: () => api.get<ActivityEvent[]>(`/activity?projectId=${projectId}&limit=5`),
    enabled: !!projectId,
  });

  const securityEvents = activity.filter((e) => e.eventType.startsWith('security.'));

  const statusColor =
    guardScore === undefined ? 'var(--text2)'
    : guardScore >= 80 ? 'var(--green)'
    : guardScore >= 50 ? 'var(--yellow)'
    : 'var(--red)';

  const statusLabel =
    guardScore === undefined ? '정보 없음'
    : guardScore >= 80 ? '안전'
    : guardScore >= 50 ? '주의'
    : '위험';

  return (
    <SectionCard title="Guard 상태">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
        <div
          style={{
            width: 10,
            height: 10,
            borderRadius: '50%',
            background: statusColor,
            flexShrink: 0,
          }}
        />
        <span style={{ fontSize: 13, fontWeight: 600, color: statusColor }}>{statusLabel}</span>
        {guardScore !== undefined && (
          <span style={{ fontSize: 11, color: 'var(--text2)' }}>({guardScore}%)</span>
        )}
      </div>

      <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 6 }}>최근 차단 이벤트</div>
      {securityEvents.length === 0 ? (
        <div style={{ fontSize: 12, color: 'var(--green)' }}>최근 차단 이벤트 없음 ✓</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {securityEvents.map((e) => (
            <div
              key={e.id}
              style={{
                fontSize: 12,
                color: 'var(--text)',
                padding: '5px 10px',
                background: 'rgba(255,107,107,0.07)',
                borderRadius: 6,
                border: '1px solid rgba(255,107,107,0.2)',
              }}
            >
              {e.detail} <span style={{ color: 'var(--text2)', marginLeft: 6 }}>({relativeTime(e.createdAt)})</span>
            </div>
          ))}
        </div>
      )}
    </SectionCard>
  );
}

// ─── Feature 3: Setup Button ──────────────────────────────────────────────────

function SetupButton({ projectId }: { projectId: string }) {
  const job = getOrCreateSetupJob(projectId);
  const [, forceUpdate] = useState(0);
  const rerender = () => forceUpdate((n) => n + 1);
  const [modalOpen, setModalOpen] = useState(false);
  const [seen, setSeen] = useState(false);

  useState(() => { job.listeners.add(rerender); });

  const runSetup = () => {
    job.state = 'running';
    job.statusMessage = '연결 중...';
    notifySetupListeners(job);

    const es = new EventSource(`/api/projects/${projectId}/setup`);

    es.addEventListener('status', (e) => {
      job.statusMessage = JSON.parse(e.data).message;
      notifySetupListeners(job);
    });

    es.addEventListener('done', (e) => {
      job.steps = JSON.parse(e.data).steps;
      job.state = 'done';
      es.close();
      notifySetupListeners(job);
    });

    es.addEventListener('error', () => {
      job.state = 'error';
      es.close();
      notifySetupListeners(job);
    });

    es.onerror = () => {
      job.state = 'error';
      es.close();
      notifySetupListeners(job);
    };
  };

  const handleClick = () => {
    if (job.state === 'idle' || job.state === 'error') {
      runSetup();
    } else if (job.state === 'done') {
      setModalOpen(true);
      setSeen(true);
    }
    // running → ignore
  };

  const { state, steps, statusMessage } = job;
  const isRunning = state === 'running';
  const isDone = state === 'done';
  const hasBadge = isDone && !seen;

  return (
    <>
      <div style={{ position: 'relative', display: 'inline-block' }}>
        {hasBadge && (
          <div style={{ position: 'absolute', top: -6, left: -6, width: 18, height: 18, background: 'var(--green)', color: '#fff', borderRadius: '50%', fontSize: 10, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1 }}>✓</div>
        )}
        <button
          onClick={handleClick}
          disabled={isRunning}
          style={{
            padding: '8px 20px',
            borderRadius: 8,
            border: '1px solid var(--border)',
            background: isDone ? 'var(--surface2)' : 'var(--accent)',
            color: isDone ? 'var(--text)' : '#fff',
            fontSize: 13,
            fontWeight: 600,
            cursor: isRunning ? 'not-allowed' : 'pointer',
            opacity: isRunning ? 0.6 : 1,
            display: 'flex',
            alignItems: 'center',
            gap: 6,
          }}
        >
          {isRunning && (
            <div style={{ width: 12, height: 12, border: '2px solid rgba(255,255,255,0.3)', borderTop: '2px solid #fff', borderRadius: '50%', animation: 'spin 1s linear infinite', flexShrink: 0 }} />
          )}
          {state === 'idle' ? '프로젝트 셋업' :
           state === 'running' ? '셋업 중...' :
           state === 'done' ? '셋업 완료 보기' :
           '프로젝트 셋업'}
          {state === 'error' && <span style={{ fontSize: 11, color: 'var(--red)', marginLeft: 2 }}>실패</span>}
        </button>
      </div>

      {isRunning && statusMessage && (
        <span style={{ fontSize: 11, color: 'var(--text2)', marginLeft: 8 }}>{statusMessage}</span>
      )}

      {isDone && modalOpen && (
        <div
          style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.6)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }}
          onClick={() => setModalOpen(false)}
        >
          <div
            style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 16, padding: 24, width: 520, maxWidth: '90vw' }}
            onClick={(e) => e.stopPropagation()}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
              <h3 style={{ fontSize: 15, fontWeight: 600 }}>셋업 결과</h3>
              <button
                onClick={() => setModalOpen(false)}
                style={{ padding: '4px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 11, cursor: 'pointer' }}
              >
                닫기
              </button>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {steps.map((step, i) => (
                <div
                  key={i}
                  style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: 'var(--surface2)', borderRadius: 8 }}
                >
                  <span style={{ width: 16, textAlign: 'center' }}>
                    {step.action === 'created'
                      ? <span style={{ color: 'var(--green)', fontSize: 12 }}>✓</span>
                      : <span style={{ color: 'var(--text2)', fontSize: 12 }}>—</span>}
                  </span>
                  <span style={{ fontSize: 13, fontWeight: 500, flex: 1 }}>{step.name}</span>
                  <span style={{ fontSize: 11, color: 'var(--text2)', maxWidth: 160, textAlign: 'right' }}>{step.detail}</span>
                </div>
              ))}
            </div>
            <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
          </div>
        </div>
      )}
    </>
  );
}

// ─── Feature 4: Setup Analysis Panel ─────────────────────────────────────────

interface SetupImprovement {
  message: string;
  target: string;
  action: string;
}

interface SetupAnalysis {
  score: number;
  guard: { strengths: string[]; improvements: SetupImprovement[] };
  guide: { strengths: string[]; improvements: SetupImprovement[] };
  gear: { strengths: string[]; improvements: SetupImprovement[] };
  summary: string;
}

// 모듈 레벨 — 셋업 상태 (컴포넌트 언마운트해도 유지)
interface SetupJob {
  state: 'idle' | 'running' | 'done' | 'error';
  steps: SetupStep[];
  statusMessage: string;
  listeners: Set<() => void>;
}
const setupJobs = new Map<string, SetupJob>();

function getOrCreateSetupJob(projectId: string): SetupJob {
  if (!setupJobs.has(projectId)) {
    setupJobs.set(projectId, { state: 'idle', steps: [], statusMessage: '', listeners: new Set() });
  }
  return setupJobs.get(projectId)!;
}

function notifySetupListeners(job: SetupJob) {
  job.listeners.forEach((fn) => fn());
}

// 모듈 레벨 — 분석 상태 (컴포넌트 언마운트해도 유지)
interface AnalysisJob {
  state: AnalysisState;
  result: SetupAnalysis | null;
  statusMessage: string;
  improved: Set<string>;
  improveProgress: { current: number; total: number };
  improveResults: Array<{ target: string; success: boolean }>;
  eventSource: EventSource | null;
  listeners: Set<() => void>;
}
const analysisJobs = new Map<string, AnalysisJob>();

function getOrCreateJob(projectId: string): AnalysisJob {
  if (!analysisJobs.has(projectId)) {
    analysisJobs.set(projectId, {
      state: 'idle', result: null, statusMessage: '', improved: new Set(),
      improveProgress: { current: 0, total: 0 }, improveResults: [],
      eventSource: null, listeners: new Set(),
    });
  }
  return analysisJobs.get(projectId)!;
}

function notifyListeners(job: AnalysisJob) {
  job.listeners.forEach((fn) => fn());
}

const setupAxisConfig = {
  guard: { label: 'Guard', dotColor: 'var(--green)' },
  guide: { label: 'Guide', dotColor: 'var(--blue)' },
  gear:  { label: 'Gear',  dotColor: '#fd963c' },
} as const;

type AnalysisState = 'idle' | 'analyzing' | 'done' | 'improving' | 'improved' | 'error';

function SetupAnalysisButton({ projectId }: { projectId: string }) {
  const queryClient = useQueryClient();
  const job = getOrCreateJob(projectId);
  const [, forceUpdate] = useState(0);
  const rerender = () => forceUpdate((n) => n + 1);
  const [modalOpen, setModalOpen] = useState(false);
  const [selectedImprovements, setSelectedImprovements] = useState<Set<string>>(new Set());

  // 마운트 시 리스너 등록, 언마운트 시 해제 (SSE는 유지)
  useState(() => { job.listeners.add(rerender); });
  const unmountRef = { current: false };
  // cleanup on unmount
  if (typeof window !== 'undefined') {
    // eslint-disable-next-line react-hooks/rules-of-hooks
    useState(() => {
      return () => { job.listeners.delete(rerender); };
    });
  }

  const analyze = () => {
    job.state = 'analyzing';
    job.statusMessage = '연결 중...';
    job.result = null;
    setSeen(false);
    job.improved = new Set();
    job.improveResults = [];
    notifyListeners(job);

    if (job.eventSource) job.eventSource.close();
    const es = new EventSource(`/api/projects/${projectId}/analyze-setup`);
    job.eventSource = es;

    es.addEventListener('status', (e) => {
      job.statusMessage = JSON.parse(e.data).message;
      notifyListeners(job);
    });

    es.addEventListener('done', (e) => {
      job.result = JSON.parse(e.data);
      job.state = 'done';
      job.eventSource = null;
      es.close();
      notifyListeners(job);
    });

    es.addEventListener('error', () => {
      job.state = 'error';
      job.eventSource = null;
      es.close();
      notifyListeners(job);
    });

    es.onerror = () => {
      job.state = 'error';
      job.eventSource = null;
      es.close();
      notifyListeners(job);
    };
  };

  const handleClick = () => {
    if (job.state === 'idle' || job.state === 'error') {
      analyze();
    } else if (job.state === 'done' || job.state === 'improved') {
      setModalOpen(true);
      setSeen(true);
    }
  };

  const toggleImprovement = (key: string) => {
    setSelectedImprovements((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const improveBatch = async () => {
    if (!job.result) return;

    const items: Array<{ key: string; target: string; action: string }> = [];
    for (const key of selectedImprovements) {
      const [axis, idxStr] = key.split('-');
      const idx = parseInt(idxStr);
      const item = job.result[axis as 'guard' | 'guide' | 'gear'].improvements[idx];
      if (item) items.push({ key, target: item.target, action: item.action });
    }

    setModalOpen(false);
    job.state = 'improving';
    job.improveProgress = { current: 0, total: items.length };
    notifyListeners(job);

    try {
      const response = await api.post<{ results: Array<{ target: string; success: boolean }> }>(
        `/projects/${projectId}/improve-batch`,
        { items: items.map(i => ({ target: i.target, action: i.action })) }
      );

      for (const item of items) {
        const r = response.results.find(r => r.target === item.target);
        if (r?.success) job.improved.add(item.key);
      }

      job.improveResults = response.results;
    } catch {
      job.improveResults = items.map(i => ({ target: i.target, success: false }));
    }

    job.state = 'improved';
    notifyListeners(job);
    queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
  };

  const { state, result: setupAnalysis, statusMessage, improveProgress, improved, improveResults } = job;

  const scoreColor = setupAnalysis
    ? setupAnalysis.score >= 80 ? 'var(--green)' : setupAnalysis.score >= 50 ? 'var(--yellow)' : 'var(--red)'
    : 'var(--text)';

  const [seen, setSeen] = useState(false);
  const isDisabled = state === 'analyzing' || state === 'improving';
  const hasBadge = !seen && (state === 'done' || state === 'improved');

  return (
    <>
      <div style={{ position: 'relative', display: 'inline-block' }}>
        {state === 'done' && (
          <div style={{ position: 'absolute', top: -6, left: -6, width: 18, height: 18, background: 'var(--red)', color: '#fff', borderRadius: '50%', fontSize: 10, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1 }}>!</div>
        )}
        {state === 'improved' && (
          <div style={{ position: 'absolute', top: -6, left: -6, width: 18, height: 18, background: 'var(--green)', color: '#fff', borderRadius: '50%', fontSize: 10, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1 }}>✓</div>
        )}
        <button
          onClick={handleClick}
          disabled={isDisabled}
          style={{
            padding: hasBadge ? '8px 20px 8px 24px' : '8px 20px',
            borderRadius: 8,
            border: '1px solid var(--border)',
            background: 'var(--surface2)',
            color: 'var(--text)',
            fontSize: 13,
            fontWeight: 600,
            cursor: isDisabled ? 'not-allowed' : 'pointer',
            opacity: isDisabled ? 0.6 : 1,
            display: 'flex',
            alignItems: 'center',
            gap: 6,
          }}
        >
          {state === 'analyzing' && (
            <div style={{ width: 12, height: 12, border: '2px solid var(--surface3)', borderTop: '2px solid var(--accent)', borderRadius: '50%', animation: 'spin 1s linear infinite', flexShrink: 0 }} />
          )}
          {state === 'idle' || state === 'error' ? '셋업 분석' :
           state === 'analyzing' ? '분석 중...' :
           state === 'done' ? '분석 결과 보기' :
           state === 'improving' ? '개선 중...' :
           state === 'improved' ? '개선 완료 보기' : '셋업 분석'}
          {state === 'error' && <span style={{ fontSize: 11, color: 'var(--red)', marginLeft: 2 }}>실패</span>}
        </button>
      </div>

      {state === 'analyzing' && statusMessage && (
        <span style={{ fontSize: 11, color: 'var(--text2)', marginLeft: 8 }}>{statusMessage}</span>
      )}

      {(state === 'done' || state === 'improved') && modalOpen && setupAnalysis && (
        <div
          style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.6)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }}
          onClick={() => setModalOpen(false)}
        >
          <div
            style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 16, padding: 24, width: 560, maxWidth: '90vw', maxHeight: '80vh', overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 0 }}
            onClick={(e) => e.stopPropagation()}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
              <h3 style={{ fontSize: 15, fontWeight: 600 }}>셋업 분석 결과</h3>
              <div style={{ display: 'flex', gap: 8 }}>
                <button
                  onClick={() => { setModalOpen(false); analyze(); }}
                  style={{ padding: '4px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 11, cursor: 'pointer' }}
                >
                  재분석
                </button>
                <button
                  onClick={() => setModalOpen(false)}
                  style={{ padding: '4px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 11, cursor: 'pointer' }}
                >
                  닫기
                </button>
              </div>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <span style={{ fontSize: 15, fontWeight: 700, color: scoreColor }}>셋업 점수: {setupAnalysis.score}/100</span>

              {(['guard', 'guide', 'gear'] as const).map((axis) => {
                const cfg = setupAxisConfig[axis];
                const { strengths, improvements } = setupAnalysis[axis];
                return (
                  <div key={axis} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <div style={{ width: 8, height: 8, borderRadius: '50%', background: cfg.dotColor, flexShrink: 0 }} />
                      <span style={{ fontSize: 13, fontWeight: 600 }}>{cfg.label}</span>
                    </div>
                    <div style={{ paddingLeft: 14, display: 'flex', flexDirection: 'column', gap: 4 }}>
                      {strengths.map((s, i) => (
                        <div key={i} style={{ fontSize: 12, color: 'var(--green)' }}>✓ {s}</div>
                      ))}
                      {improvements.map((item, i) => {
                        const key = `${axis}-${i}`;
                        const done = improved.has(key);
                        const checked = selectedImprovements.has(key);
                        return (
                          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                            {done ? (
                              <span style={{ fontSize: 12, color: 'var(--green)' }}>✓ {item.message} <span style={{ fontSize: 11, color: 'var(--text2)' }}>반영됨</span></span>
                            ) : (
                              <>
                                <input
                                  type="checkbox"
                                  checked={checked}
                                  onChange={() => toggleImprovement(key)}
                                  style={{ cursor: 'pointer', flexShrink: 0 }}
                                />
                                <span style={{ fontSize: 12, color: 'var(--yellow)' }}>⚠ {item.message}</span>
                              </>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  </div>
                );
              })}

              <div style={{ fontSize: 11, color: 'var(--text2)', paddingTop: 4, borderTop: '1px solid var(--border)' }}>
                {setupAnalysis.summary}
              </div>

              {state === 'improved' && improveResults.length > 0 && (
                <div style={{ fontSize: 11, color: 'var(--text2)', paddingTop: 4 }}>
                  {`${improveResults.length}개 중 ${improveResults.filter((r) => r.success).length}개 반영 성공`}
                </div>
              )}

              <div style={{ display: 'flex', justifyContent: 'center', paddingTop: 4 }}>
                <button
                  onClick={improveBatch}
                  disabled={selectedImprovements.size === 0}
                  style={{
                    padding: '8px 20px',
                    borderRadius: 8,
                    border: 'none',
                    background: selectedImprovements.size === 0 ? 'var(--surface3)' : 'var(--accent)',
                    color: selectedImprovements.size === 0 ? 'var(--text2)' : '#fff',
                    fontSize: 13,
                    fontWeight: 600,
                    cursor: selectedImprovements.size === 0 ? 'not-allowed' : 'pointer',
                  }}
                >
                  {`선택 항목 일괄 개선 (${selectedImprovements.size}개)`}
                </button>
              </div>
            </div>

            <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
          </div>
        </div>
      )}
    </>
  );
}

// ─── Feature 5: Inline Task Input + Log Panel ─────────────────────────────────

function TaskInputBar({ projectId }: { projectId: string }) {
  const [input, setInput] = useState('');
  const [running, setRunning] = useState(false);
  const [logs, setLogs] = useState<string[]>([]);
  const [logOpen, setLogOpen] = useState(false);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const logRef = useRef<HTMLDivElement>(null);
  const esRef = useRef<EventSource | null>(null);

  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [logs]);

  useEffect(() => {
    return () => {
      esRef.current?.close();
    };
  }, []);

  const run = async () => {
    if (!input.trim() || running) return;
    setRunning(true);
    setLogs([]);
    setExitCode(null);
    setLogOpen(true);

    try {
      const task = await api.post<Task>('/tasks', { projectId, title: input.trim() });
      const runResult = await api.post<TaskRun>(`/tasks/${task.id}/run`, {});

      const es = new EventSource(`/api/tasks/runs/${runResult.id}/stream`);
      esRef.current = es;

      es.onmessage = (e) => {
        try {
          const data = JSON.parse(e.data);
          if (data.type === 'log') {
            setLogs((prev) => [...prev, data.message]);
          } else if (data.type === 'done') {
            setExitCode(data.exitCode ?? 0);
            setRunning(false);
            es.close();
          }
        } catch {
          setLogs((prev) => [...prev, e.data]);
        }
      };

      es.onerror = () => {
        setExitCode(1);
        setRunning(false);
        es.close();
      };

      setInput('');
    } catch {
      setLogs(['실행 중 오류가 발생했습니다.']);
      setExitCode(1);
      setRunning(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') run();
  };

  return (
    <div
      style={{
        position: 'sticky',
        bottom: 0,
        background: 'var(--surface)',
        borderTop: '1px solid var(--border)',
        zIndex: 50,
      }}
    >
      {logOpen && (
        <div
          ref={logRef}
          style={{
            height: 300,
            overflowY: 'auto',
            background: '#1a1a2e',
            color: '#e0e0e0',
            fontFamily: 'monospace',
            fontSize: 12,
            padding: '10px 14px',
            borderTop: '1px solid var(--border)',
          }}
        >
          {logs.map((line, i) => (
            <div key={i} style={{ lineHeight: 1.6 }}>{line}</div>
          ))}
          {exitCode !== null && (
            <div
              style={{
                marginTop: 8,
                fontWeight: 600,
                color: exitCode === 0 ? '#00cec9' : '#ff6b6b',
              }}
            >
              {exitCode === 0 ? `✓ 완료 (exit code: 0)` : `✗ 실패 (exit code: ${exitCode})`}
            </div>
          )}
        </div>
      )}

      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          padding: '12px 18px',
        }}
      >
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          disabled={running}
          placeholder="에이전트에게 지시..."
          style={{
            flex: 1,
            padding: '9px 14px',
            borderRadius: 8,
            border: '1px solid var(--border)',
            background: 'var(--surface2)',
            color: 'var(--text)',
            fontSize: 13,
            outline: 'none',
            opacity: running ? 0.6 : 1,
          }}
        />
        <button
          onClick={run}
          disabled={running || !input.trim()}
          style={{
            padding: '9px 18px',
            borderRadius: 8,
            border: 'none',
            background: running || !input.trim() ? 'var(--surface3)' : 'var(--accent)',
            color: '#fff',
            fontSize: 13,
            fontWeight: 600,
            cursor: running || !input.trim() ? 'not-allowed' : 'pointer',
          }}
        >
          {running ? '실행 중...' : '실행'}
        </button>
        {logs.length > 0 && (
          <button
            onClick={() => setLogOpen((v) => !v)}
            style={{
              padding: '9px 12px',
              borderRadius: 8,
              border: '1px solid var(--border)',
              background: 'var(--surface2)',
              color: 'var(--text2)',
              fontSize: 12,
              cursor: 'pointer',
            }}
          >
            {logOpen ? '접기' : '로그'}
          </button>
        )}
      </div>
    </div>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export function ProjectDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [claudeMdExpanded, setClaudeMdExpanded] = useState(false);
  const [claudeMdEditing, setClaudeMdEditing] = useState(false);
  const [claudeMdDraft, setClaudeMdDraft] = useState('');
  const [guidanceModal, setGuidanceModal] = useState<{ title: string; content: string } | null>(null);
  const [addingConvention, setAddingConvention] = useState(false);
  const [conventionCategory, setConventionCategory] = useState('');
  const [conventionRule, setConventionRule] = useState('');
  const [expandedDoc, setExpandedDoc] = useState<string | null>(null);
  const [editingDoc, setEditingDoc] = useState<string | null>(null);
  const [docDraft, setDocDraft] = useState('');
  const [docContents, setDocContents] = useState<Record<string, string>>({});
  const [addingDoc, setAddingDoc] = useState(false);
  const [newDocName, setNewDocName] = useState('');
  const [newDocContent, setNewDocContent] = useState('');

  // ── Mutations ──────────────────────────────────────────────────────────────

  const setupClaudeMd = useMutation({
    mutationFn: () => api.post(`/projects/${id}/setup/claudemd`, {}),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['project-analysis'] }),
  });
  const updateClaudeMd = useMutation({
    mutationFn: (content: string) => api.patch(`/projects/${id}/setup/claudemd`, { content }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      setClaudeMdEditing(false);
    },
  });
  const deleteClaudeMd = useMutation({
    mutationFn: () => api.delete(`/projects/${id}/setup/claudemd`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['project-analysis'] }),
  });
  const setupHooks = useMutation({
    mutationFn: () => api.post(`/projects/${id}/setup/hooks`, {}),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['project-analysis'] }),
  });
  const deleteHooks = useMutation({
    mutationFn: () => api.delete(`/projects/${id}/setup/hooks`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['project-analysis'] }),
  });
  const setupConventions = useMutation({
    mutationFn: () => api.post(`/projects/${id}/setup/conventions`, {}),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['project-analysis'] }),
  });
  const addConvention = useMutation({
    mutationFn: ({ category, rule }: { category: string; rule: string }) =>
      api.post(`/conventions/${id}`, { category, rule }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['db-conventions', id] });
      setAddingConvention(false);
      setConventionCategory('');
      setConventionRule('');
    },
  });
  const deleteConvention = useMutation({
    mutationFn: (conventionId: string) => api.delete(`/conventions/${id}/${conventionId}`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['db-conventions', id] }),
  });
  const updateDoc = useMutation({
    mutationFn: ({ name, content }: { name: string; content: string }) =>
      api.put(`/projects/${id}/docs/${name}`, { content }),
    onSuccess: (_data, { name, content }) => {
      setDocContents((prev) => ({ ...prev, [name]: content }));
      setEditingDoc(null);
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
    },
  });
  const addDoc = useMutation({
    mutationFn: async ({ name, content }: { name: string; content: string }) => {
      await api.put(`/projects/${id}/docs/${name}`, { content });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      setAddingDoc(false);
      setNewDocName('');
      setNewDocContent('');
    },
  });
  const deleteDoc = useMutation({
    mutationFn: (name: string) => api.delete(`/projects/${id}/docs/${name}`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['project-analysis'] }),
  });

  // ── Queries ────────────────────────────────────────────────────────────────

  const { data: project, isLoading } = useQuery({
    queryKey: ['project', id],
    queryFn: () => api.get<Project>(`/projects/${id}`),
    enabled: !!id,
  });

  const { data: analysis, isLoading: analysisLoading } = useQuery({
    queryKey: ['project-analysis', id, project?.path],
    queryFn: () => api.post<ProjectAnalysis>('/projects/analyze', { path: project!.path }),
    enabled: !!project?.path,
  });

  const { data: allAgents } = useQuery({
    queryKey: ['agents'],
    queryFn: () => api.get<Agent[]>('/agents'),
  });

  const { data: allTasks } = useQuery({
    queryKey: ['tasks'],
    queryFn: () => api.get<Task[]>('/tasks'),
  });

  const { data: costsByProject } = useQuery({
    queryKey: ['costs-by-project'],
    queryFn: () => api.get<CostByProject[]>('/costs/by-project'),
  });

  const { data: relations } = useQuery({
    queryKey: ['relations', id],
    queryFn: () => api.get<Relation[]>(`/relations/${id}`),
    enabled: !!id,
  });

  const { data: dbConventions = [] } = useQuery({
    queryKey: ['db-conventions', id],
    queryFn: () => api.get<{ id: string; category: string; rule: string }[]>(`/conventions/${id}`),
    enabled: !!id,
  });

  // ── Derived data ───────────────────────────────────────────────────────────

  const agents = (allAgents ?? []).filter((a) => a.projectId === id);
  const tasks = (allTasks ?? []).filter((t) => t.projectId === id).slice(0, 10);
  const cost = (costsByProject ?? []).find((c) => c.projectId === id);

  // ── Early returns ──────────────────────────────────────────────────────────

  if (isLoading) {
    return <div style={{ padding: '24px 28px', color: 'var(--text2)' }}>Loading...</div>;
  }

  if (!project) {
    return <div style={{ padding: '24px 28px', color: 'var(--text2)' }}>Project not found.</div>;
  }

  const hasPath = !!project.path;

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '24px 28px', paddingBottom: 0 }}>
      {/* 1. Header */}
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', gap: 12 }}>
        <button
          onClick={() => navigate('/projects')}
          style={{
            padding: '6px 10px',
            borderRadius: 8,
            border: '1px solid var(--border)',
            background: 'var(--surface2)',
            color: 'var(--text2)',
            fontSize: 12,
            cursor: 'pointer',
          }}
        >
          ← Back
        </button>
        <div
          style={{
            width: 36,
            height: 36,
            background: 'var(--surface3)',
            borderRadius: 8,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 18,
          }}
        >
          📦
        </div>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>{project.name}</h1>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>

        {/* 2. 프로젝트 셋업 + 셋업 분석 */}
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
          {id && <SetupButton projectId={id} />}
          {id && <SetupAnalysisButton projectId={id} />}
        </div>

        {/* 3 + 4. 프로젝트 개요 (with Score Panel) */}
        <SectionCard title="프로젝트 개요">
          {/* Feature 1: Guard/Guide/Gear scores at the top */}
          {analysis?.scores && <ScorePanel scores={analysis.scores} />}

          <InfoRow label="Name" value={project.name} />
          <InfoRow label="Path" value={project.path} />
          <InfoRow label="Git URL" value={project.gitUrl} />
          <InfoRow label="Description" value={project.description} />
          <InfoRow label="Created" value={new Date(project.createdAt).toLocaleDateString()} />

          {hasPath && (
            <div style={{ marginTop: 12 }}>
              {analysisLoading ? (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  <SkeletonBlock width={60} height={22} />
                  <SkeletonBlock width={80} height={22} />
                  <SkeletonBlock width={50} height={22} />
                </div>
              ) : analysis ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  {analysis.techStack.length > 0 && (
                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                      <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>스택</span>
                      {analysis.techStack.map((t) => (
                        <Badge key={t} color="blue">{t}</Badge>
                      ))}
                    </div>
                  )}
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>Git</span>
                    {analysis.git.isRepo ? (
                      <Badge color="green">✓ {analysis.git.branch ?? 'repo'}</Badge>
                    ) : (
                      <Badge color="gray">not a repo</Badge>
                    )}
                  </div>
                </div>
              ) : null}
            </div>
          )}
        </SectionCard>

        {/* 5. Guard Status */}
        {id && (
          <GuardSection
            projectId={id}
            guardScore={analysis?.scores?.guard.score}
          />
        )}

        {/* 7. CLAUDE.md */}
        <SectionCard title="CLAUDE.md">
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 CLAUDE.md 상태를 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <SkeletonBlock height={14} />
              <SkeletonBlock width="70%" height={14} />
            </div>
          ) : analysis?.claudeMd.exists ? (
            <div>
              {claudeMdEditing ? (
                <div>
                  <textarea
                    value={claudeMdDraft}
                    onChange={(e) => setClaudeMdDraft(e.target.value)}
                    style={{
                      width: '100%',
                      minHeight: 200,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: 12,
                      color: 'var(--text)',
                      resize: 'vertical',
                      boxSizing: 'border-box',
                    }}
                  />
                  <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                    <button
                      onClick={() => updateClaudeMd.mutate(claudeMdDraft)}
                      disabled={updateClaudeMd.isPending}
                      style={{
                        padding: '5px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--surface2)',
                        color: 'var(--text)',
                        fontSize: 12,
                        cursor: updateClaudeMd.isPending ? 'not-allowed' : 'pointer',
                      }}
                    >
                      {updateClaudeMd.isPending ? '저장 중...' : '저장'}
                    </button>
                    <button
                      onClick={() => setClaudeMdEditing(false)}
                      style={{
                        padding: '5px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'transparent',
                        color: 'var(--text2)',
                        fontSize: 12,
                        cursor: 'pointer',
                      }}
                    >
                      취소
                    </button>
                  </div>
                </div>
              ) : (
                <div>
                  <div
                    style={{
                      fontSize: 12,
                      color: 'var(--text)',
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: 12,
                      whiteSpace: 'pre-wrap',
                      wordBreak: 'break-all',
                      maxHeight: claudeMdExpanded ? 'none' : 120,
                      overflow: 'hidden',
                    }}
                  >
                    {analysis.claudeMd.content ?? ''}
                  </div>
                  <div style={{ display: 'flex', gap: 8, marginTop: 8, alignItems: 'center' }}>
                    {(analysis.claudeMd.content?.length ?? 0) > 200 && (
                      <button
                        onClick={() => setClaudeMdExpanded((v) => !v)}
                        style={{
                          padding: '4px 10px',
                          borderRadius: 6,
                          border: '1px solid var(--border)',
                          background: 'transparent',
                          color: 'var(--text2)',
                          fontSize: 11,
                          cursor: 'pointer',
                        }}
                      >
                        {claudeMdExpanded ? '접기' : '전체 보기'}
                      </button>
                    )}
                    <button
                      onClick={() => {
                        setClaudeMdDraft(analysis.claudeMd.content ?? '');
                        setClaudeMdEditing(true);
                      }}
                      style={{
                        padding: '4px 10px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--surface2)',
                        color: 'var(--text)',
                        fontSize: 12,
                        cursor: 'pointer',
                      }}
                    >
                      수정
                    </button>
                    <button
                      onClick={() => {
                        if (window.confirm('CLAUDE.md를 삭제하시겠습니까?')) {
                          deleteClaudeMd.mutate();
                        }
                      }}
                      disabled={deleteClaudeMd.isPending}
                      style={{
                        padding: '4px 10px',
                        borderRadius: 6,
                        border: '1px solid var(--red)',
                        background: 'transparent',
                        color: 'var(--red)',
                        fontSize: 12,
                        cursor: deleteClaudeMd.isPending ? 'not-allowed' : 'pointer',
                      }}
                    >
                      {deleteClaudeMd.isPending ? '삭제 중...' : '삭제'}
                    </button>
                  </div>

                </div>
              )}
            </div>
          ) : (
            <div>
              <div style={{ fontSize: 13, color: 'var(--text2)', marginBottom: 10 }}>
                이 프로젝트에 CLAUDE.md가 없습니다. CLAUDE.md를 추가하면 Claude가 프로젝트 컨텍스트를 자동으로 이해합니다.
              </div>
              <button
                onClick={() => setupClaudeMd.mutate()}
                disabled={setupClaudeMd.isPending}
                style={{
                  padding: '8px 16px',
                  borderRadius: 8,
                  border: 'none',
                  background: setupClaudeMd.isPending ? 'var(--surface3)' : 'var(--accent)',
                  color: '#fff',
                  fontSize: 13,
                  fontWeight: 600,
                  cursor: setupClaudeMd.isPending ? 'not-allowed' : 'pointer',
                  opacity: setupClaudeMd.isPending ? 0.6 : 1,
                }}
              >
                {setupClaudeMd.isPending ? '생성 중...' : 'CLAUDE.md 생성'}
              </button>
              {setupClaudeMd.isError && (
                <span style={{ fontSize: 11, color: 'var(--red)', marginLeft: 8 }}>생성 실패</span>
              )}
            </div>
          )}
        </SectionCard>

        {/* 7. Hooks */}
        <SectionCard title="Hooks">
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 Hook 상태를 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <SkeletonBlock height={14} />
              <SkeletonBlock width="80%" height={14} />
            </div>
          ) : analysis && analysis.hooks.length > 0 ? (
            <div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {analysis.hooks.map((hook, i) => (
                  <div
                    key={i}
                    style={{
                      padding: '10px 12px',
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                    }}
                  >
                    <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>
                      <Badge color="yellow">{hook.event}</Badge>
                    </div>
                    {hook.commands.map((cmd, j) => (
                      <div key={j} style={{ fontSize: 11, color: 'var(--text2)', fontFamily: 'monospace', marginTop: 2 }}>
                        {cmd}
                      </div>
                    ))}
                  </div>
                ))}
              </div>
              <div style={{ marginTop: 10 }}>
                <button
                  onClick={() => {
                    if (window.confirm('모든 Hook 설정을 초기화하시겠습니까?')) {
                      deleteHooks.mutate();
                    }
                  }}
                  disabled={deleteHooks.isPending}
                  style={{
                    padding: '5px 12px',
                    borderRadius: 6,
                    border: '1px solid var(--red)',
                    background: 'transparent',
                    color: 'var(--red)',
                    fontSize: 12,
                    cursor: deleteHooks.isPending ? 'not-allowed' : 'pointer',
                  }}
                >
                  {deleteHooks.isPending ? '초기화 중...' : 'Hook 초기화'}
                </button>
              </div>
            </div>
          ) : (
            <div>
              <div style={{ fontSize: 13, color: 'var(--text2)', marginBottom: 10 }}>
                보안 Hook을 적용하면 위험 명령을 자동 차단합니다.
              </div>
              <button
                onClick={() => setupHooks.mutate()}
                disabled={setupHooks.isPending}
                style={{
                  padding: '8px 16px',
                  borderRadius: 8,
                  border: 'none',
                  background: setupHooks.isPending ? 'var(--surface3)' : 'var(--accent)',
                  color: '#fff',
                  fontSize: 13,
                  fontWeight: 600,
                  cursor: setupHooks.isPending ? 'not-allowed' : 'pointer',
                  opacity: setupHooks.isPending ? 0.6 : 1,
                }}
              >
                {setupHooks.isPending ? '적용 중...' : '보안 Hook 적용'}
              </button>
              {setupHooks.isError && (
                <span style={{ fontSize: 11, color: 'var(--red)', marginLeft: 8 }}>적용 실패</span>
              )}
            </div>
          )}
        </SectionCard>

        {/* 8. 프로젝트 문서 */}
        <SectionCard title="프로젝트 문서">
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 문서 목록을 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', gap: 6 }}>
              <SkeletonBlock width={70} height={22} />
              <SkeletonBlock width={90} height={22} />
            </div>
          ) : analysis && analysis.docs.length > 0 ? (
            <div>
              {analysis.docs.map((d) => (
                <div key={d.name} style={{ borderBottom: '1px solid var(--border)' }}>
                  <div
                    style={{ display: 'flex', justifyContent: 'space-between', cursor: 'pointer', padding: '8px 0', alignItems: 'center' }}
                    onClick={async () => {
                      if (expandedDoc === d.name) {
                        setExpandedDoc(null);
                        setEditingDoc(null);
                      } else {
                        setExpandedDoc(d.name);
                        setEditingDoc(null);
                        if (!docContents[d.name]) {
                          try {
                            const result = await api.get<{ name: string; content: string }>(`/projects/${id}/docs/${d.name}`);
                            setDocContents((prev) => ({ ...prev, [d.name]: result.content }));
                          } catch {
                            setDocContents((prev) => ({ ...prev, [d.name]: '(불러오기 실패)' }));
                          }
                        }
                      }
                    }}
                  >
                    <span style={{ fontSize: 13, fontWeight: 500 }}>{d.name}</span>
                    <span style={{ fontSize: 11, color: 'var(--text2)' }}>{expandedDoc === d.name ? '▼' : '▶'}</span>
                  </div>
                  {expandedDoc === d.name && (
                    <div style={{ paddingBottom: 10 }}>
                      {editingDoc === d.name ? (
                        <div>
                          <textarea
                            value={docDraft}
                            onChange={(e) => setDocDraft(e.target.value)}
                            style={{
                              width: '100%',
                              minHeight: 200,
                              fontSize: 12,
                              fontFamily: 'monospace',
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                              borderRadius: 8,
                              padding: 12,
                              color: 'var(--text)',
                              resize: 'vertical',
                              boxSizing: 'border-box',
                            }}
                          />
                          <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                            <button
                              onClick={() => updateDoc.mutate({ name: d.name, content: docDraft })}
                              disabled={updateDoc.isPending}
                              style={{
                                padding: '5px 12px',
                                borderRadius: 6,
                                border: '1px solid var(--border)',
                                background: 'var(--surface2)',
                                color: 'var(--text)',
                                fontSize: 12,
                                cursor: updateDoc.isPending ? 'not-allowed' : 'pointer',
                              }}
                            >
                              {updateDoc.isPending ? '저장 중...' : '저장'}
                            </button>
                            <button
                              onClick={() => setEditingDoc(null)}
                              style={{
                                padding: '5px 12px',
                                borderRadius: 6,
                                border: '1px solid var(--border)',
                                background: 'transparent',
                                color: 'var(--text2)',
                                fontSize: 12,
                                cursor: 'pointer',
                              }}
                            >
                              취소
                            </button>
                          </div>
                        </div>
                      ) : (
                        <div>
                          <div
                            style={{
                              fontSize: 12,
                              fontFamily: 'monospace',
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                              borderRadius: 8,
                              padding: 12,
                              whiteSpace: 'pre-wrap',
                              maxHeight: 200,
                              overflowY: 'auto',
                            }}
                          >
                            {docContents[d.name] ?? '불러오는 중...'}
                          </div>
                          <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                            <button
                              onClick={() => {
                                setDocDraft(docContents[d.name] ?? '');
                                setEditingDoc(d.name);
                              }}
                              style={{
                                padding: '4px 10px',
                                borderRadius: 6,
                                border: '1px solid var(--border)',
                                background: 'var(--surface2)',
                                color: 'var(--text)',
                                fontSize: 12,
                                cursor: 'pointer',
                              }}
                            >
                              수정
                            </button>
                            <button
                              onClick={() => {
                                if (window.confirm(`'${d.name}.md'를 삭제하시겠습니까?`)) {
                                  deleteDoc.mutate(d.name);
                                }
                              }}
                              disabled={deleteDoc.isPending}
                              style={{
                                padding: '4px 10px',
                                borderRadius: 6,
                                border: '1px solid var(--red)',
                                background: 'transparent',
                                color: 'var(--red)',
                                fontSize: 12,
                                cursor: deleteDoc.isPending ? 'not-allowed' : 'pointer',
                              }}
                            >
                              {deleteDoc.isPending ? '삭제 중...' : '삭제'}
                            </button>
                          </div>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
              {!addingDoc && (
                <button
                  onClick={() => setAddingDoc(true)}
                  style={{ marginTop: 8, padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12, cursor: 'pointer' }}
                >
                  + 문서 추가
                </button>
              )}
              {addingDoc && (
                <div style={{ marginTop: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <input
                    placeholder="문서 이름 (예: testing)"
                    value={newDocName}
                    onChange={(e) => setNewDocName(e.target.value.replace(/[^a-zA-Z0-9_-]/g, ''))}
                    style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12 }}
                  />
                  <textarea
                    placeholder="문서 내용 (마크다운)"
                    value={newDocContent}
                    onChange={(e) => setNewDocContent(e.target.value)}
                    style={{ width: '100%', minHeight: 150, fontSize: 12, fontFamily: 'monospace', background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 8, padding: 12, color: 'var(--text)', resize: 'vertical', boxSizing: 'border-box' }}
                  />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button
                      onClick={() => {
                        if (newDocName.trim()) {
                          addDoc.mutate({ name: newDocName.trim(), content: newDocContent });
                        }
                      }}
                      disabled={!newDocName.trim() || addDoc.isPending}
                      style={{ padding: '5px 12px', borderRadius: 6, border: 'none', background: !newDocName.trim() ? 'var(--surface3)' : 'var(--accent)', color: '#fff', fontSize: 12, fontWeight: 600, cursor: !newDocName.trim() ? 'not-allowed' : 'pointer', opacity: !newDocName.trim() ? 0.6 : 1 }}
                    >
                      {addDoc.isPending ? '추가 중...' : '추가'}
                    </button>
                    <button
                      onClick={() => { setAddingDoc(false); setNewDocName(''); setNewDocContent(''); }}
                      style={{ padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 12, cursor: 'pointer' }}
                    >
                      취소
                    </button>
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div>
              <div style={{ fontSize: 13, color: 'var(--text2)', marginBottom: 8 }}>
                프로젝트 셋업을 실행하면 자동으로 생성됩니다. (.ddalkak/docs/)
              </div>
              <button
                onClick={() => setAddingDoc(true)}
                style={{ padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12, cursor: 'pointer' }}
              >
                + 문서 추가
              </button>
              {addingDoc && (
                <div style={{ marginTop: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <input
                    placeholder="문서 이름 (예: testing)"
                    value={newDocName}
                    onChange={(e) => setNewDocName(e.target.value.replace(/[^a-zA-Z0-9_-]/g, ''))}
                    style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12 }}
                  />
                  <textarea
                    placeholder="문서 내용 (마크다운)"
                    value={newDocContent}
                    onChange={(e) => setNewDocContent(e.target.value)}
                    style={{ width: '100%', minHeight: 150, fontSize: 12, fontFamily: 'monospace', background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 8, padding: 12, color: 'var(--text)', resize: 'vertical', boxSizing: 'border-box' }}
                  />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button
                      onClick={() => {
                        if (newDocName.trim()) {
                          addDoc.mutate({ name: newDocName.trim(), content: newDocContent });
                        }
                      }}
                      disabled={!newDocName.trim() || addDoc.isPending}
                      style={{ padding: '5px 12px', borderRadius: 6, border: 'none', background: !newDocName.trim() ? 'var(--surface3)' : 'var(--accent)', color: '#fff', fontSize: 12, fontWeight: 600, cursor: !newDocName.trim() ? 'not-allowed' : 'pointer', opacity: !newDocName.trim() ? 0.6 : 1 }}
                    >
                      {addDoc.isPending ? '추가 중...' : '추가'}
                    </button>
                    <button
                      onClick={() => { setAddingDoc(false); setNewDocName(''); setNewDocContent(''); }}
                      style={{ padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 12, cursor: 'pointer' }}
                    >
                      취소
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}
        </SectionCard>

        {/* 10. 스킬 */}
        <SectionCard title="스킬">
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 스킬 목록을 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', gap: 6 }}>
              <SkeletonBlock width={70} height={22} />
              <SkeletonBlock width={90} height={22} />
            </div>
          ) : analysis && analysis.skills.length > 0 ? (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {analysis.skills.map((s) => (
                <Badge key={s.name} color="blue">{s.name}</Badge>
              ))}
            </div>
          ) : (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>
              .ddalkak/skills/ 디렉토리에 스킬을 추가하세요.
            </div>
          )}
        </SectionCard>

        {/* 10. 에이전트 */}
        <SectionCard title={`에이전트 (${agents.length})`}>
          {hasPath && analysis && (
            <>
              {analysis.agents.length > 0 && (
                <div style={{ marginBottom: 12 }}>
                  <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>.claude/agents/</div>
                  <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                    {analysis.agents.map((a) => (
                      <Badge key={a.name} color="blue">{a.name}</Badge>
                    ))}
                  </div>
                </div>
              )}
              <div style={{ marginBottom: 12 }}>
                <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>설치된 CLI</div>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {(['claude', 'codex', 'cursor'] as const).map((key) => {
                    const labels: Record<string, string> = { claude: 'Claude', codex: 'Codex', cursor: 'Cursor' };
                    const installed = analysis.installedCLIs[key];
                    return (
                      <Badge key={key} color={installed ? 'green' : 'gray'}>
                        {labels[key]} {installed ? '✓' : '✗'}
                      </Badge>
                    );
                  })}
                </div>
              </div>
            </>
          )}
          {agents.length === 0 && !analysis?.agents.length ? (
            <div style={{ padding: '8px 0', textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No agents</div>
          ) : agents.length > 0 && (
            <div>
              <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>등록된 에이전트</div>
              {agents.map((agent) => {
                const adapter = adapterIcons[agent.adapterType] ?? { icon: '?', color: '#888' };
                const status = agentStatusColors[agent.status] ?? agentStatusColors.idle;
                return (
                  <div
                    key={agent.id}
                    style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--border)' }}
                  >
                    <div
                      style={{
                        width: 28,
                        height: 28,
                        borderRadius: 6,
                        background: `linear-gradient(135deg, ${adapter.color}, ${adapter.color}88)`,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: 11,
                        fontWeight: 700,
                        color: '#fff',
                      }}
                    >
                      {adapter.icon}
                    </div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 13, fontWeight: 500 }}>{agent.name}</div>
                      <div style={{ fontSize: 11, color: 'var(--text2)' }}>{agent.adapterType.replace('_', ' ')}</div>
                    </div>
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 6,
                        fontSize: 11,
                        fontWeight: 600,
                        background: status.bg,
                        color: status.color,
                      }}
                    >
                      {agent.status}
                    </span>
                  </div>
                );
              })}
            </div>
          )}
        </SectionCard>

        {/* 11. 워크플로우 */}
        <SectionCard title="워크플로우">
          {hasPath && analysis ? (
            analysis.workflows && analysis.workflows.length > 0 ? (
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {analysis.workflows.map((w) => (
                  <Badge key={w.name} color="orange">{w.name}</Badge>
                ))}
              </div>
            ) : (
              <div style={{ fontSize: 13, color: 'var(--text2)' }}>
                프로젝트 셋업을 실행하면 자동으로 생성됩니다.
              </div>
            )
          ) : (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>
              프로젝트 경로를 설정하세요.
            </div>
          )}
        </SectionCard>

        {/* 12. 비용 요약 */}
        <SectionCard title="Cost Summary">
          {cost ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 12, color: 'var(--text2)' }}>Total Spend</span>
                <span style={{ fontSize: 18, fontWeight: 700 }}>{formatUsd(cost.totalUsd)}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 12, color: 'var(--text2)' }}>Input Tokens</span>
                <span style={{ fontSize: 13 }}>{formatTokens(cost.tokensIn)}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 12, color: 'var(--text2)' }}>Output Tokens</span>
                <span style={{ fontSize: 13 }}>{formatTokens(cost.tokensOut)}</span>
              </div>
            </div>
          ) : (
            <div style={{ color: 'var(--text2)', fontSize: 13 }}>No cost data yet</div>
          )}
        </SectionCard>

        {/* 12. 최근 태스크 */}
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
          <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
            Recent Tasks ({tasks.length})
          </div>
          <div style={{ padding: '8px 18px' }}>
            {tasks.length === 0 ? (
              <div style={{ padding: 16, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No tasks</div>
            ) : tasks.map((task) => {
              const s = statusStyle[task.status] ?? statusStyle.todo;
              return (
                <div
                  key={task.id}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    padding: '8px 0',
                    borderBottom: '1px solid var(--border)',
                  }}
                >
                  <div style={{ fontSize: 13, flex: 1, marginRight: 8 }}>{task.title}</div>
                  <span
                    style={{
                      padding: '2px 8px',
                      borderRadius: 6,
                      fontSize: 11,
                      fontWeight: 600,
                      background: s.bg,
                      color: s.color,
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {task.status}
                  </span>
                </div>
              );
            })}
          </div>
        </div>

        {/* 13. 관련 프로젝트 */}
        {(relations ?? []).length > 0 && (
          <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
            <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
              Related Projects
            </div>
            <div style={{ padding: '8px 18px' }}>
              {(relations ?? []).map((rel) => {
                const other = rel.sourceProject.id === id ? rel.targetProject : rel.sourceProject;
                const direction = rel.sourceProject.id === id ? '→' : '←';
                return (
                  <div
                    key={rel.id}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 8,
                      padding: '8px 0',
                      borderBottom: '1px solid var(--border)',
                      cursor: 'pointer',
                    }}
                    onClick={() => navigate(`/projects/${other.id}`)}
                  >
                    <span style={{ fontSize: 13, color: 'var(--text2)' }}>{direction}</span>
                    <span style={{ fontSize: 13, fontWeight: 500 }}>{other.name}</span>
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 6,
                        fontSize: 11,
                        background: 'var(--surface3)',
                        color: 'var(--text2)',
                      }}
                    >
                      {rel.type}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        )}
      </div>

      {/* 14. Feature 5: Inline Task Input Bar (sticky bottom) */}
      {id && <TaskInputBar projectId={id} />}

      {/* Modals */}
      {guidanceModal && (
        <GuidanceModal
          title={guidanceModal.title}
          content={guidanceModal.content}
          onClose={() => setGuidanceModal(null)}
        />
      )}

    </div>
  );
}
