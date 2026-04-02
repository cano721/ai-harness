import { useQuery } from '@tanstack/react-query';
import { useParams, useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';

interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: string;
  status: string;
  config: Record<string, unknown>;
  lastHeartbeat?: string;
  createdAt: string;
}

interface Task {
  id: string;
  projectId: string;
  title: string;
  status: string;
  createdAt: string;
}

interface TaskRun {
  id: string;
  taskId: string;
  agentId: string;
  status: string;
  startedAt: string;
  finishedAt?: string;
  tokensIn?: number;
  tokensOut?: number;
  costUsd?: number;
}

interface CostByAgent {
  agentId: string;
  agentName: string;
  adapterType: string;
  totalUsd: number;
  tokensIn: number;
  tokensOut: number;
}

interface ActivityEntry {
  id: string;
  agentId?: string;
  projectId?: string;
  eventType: string;
  detail?: Record<string, unknown>;
  createdAt: string;
}

const statusColors: Record<string, { bg: string; color: string }> = {
  running: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  idle: { bg: 'var(--surface3)', color: 'var(--text2)' },
  paused: { bg: 'rgba(254,202,87,0.1)', color: 'var(--yellow)' },
  error: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
  terminated: { bg: 'var(--surface3)', color: 'var(--text2)' },
};

const taskStatusStyle: Record<string, { bg: string; color: string }> = {
  todo: { bg: 'var(--surface3)', color: 'var(--text2)' },
  in_progress: { bg: 'rgba(116,185,255,0.1)', color: 'var(--blue)' },
  done: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  blocked: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

const runStatusStyle: Record<string, { bg: string; color: string }> = {
  running: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  success: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  failed: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
  timeout: { bg: 'rgba(254,202,87,0.1)', color: 'var(--yellow)' },
};

const adapterIcons: Record<string, { icon: string; color: string }> = {
  claude_local: { icon: 'C', color: '#d4a574' },
  codex_local: { icon: 'X', color: '#74b9ff' },
  cursor_local: { icon: 'Cu', color: '#a29bfe' },
};

function formatUsd(n: number) {
  return `$${n.toFixed(4)}`;
}

function formatTokens(n: number) {
  return n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(0)}K` : String(n);
}

function formatRelativeTime(dateStr: string) {
  const diff = Date.now() - new Date(dateStr).getTime();
  const sec = Math.floor(diff / 1000);
  if (sec < 60) return `${sec}s ago`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  return new Date(dateStr).toLocaleDateString();
}

function InfoRow({ label, value }: { label: string; value?: string }) {
  if (!value) return null;
  return (
    <div style={{ display: 'flex', gap: 12, padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
      <span style={{ fontSize: 12, color: 'var(--text2)', width: 110, flexShrink: 0 }}>{label}</span>
      <span style={{ fontSize: 12, color: 'var(--text)', wordBreak: 'break-all' }}>{value}</span>
    </div>
  );
}

export function AgentDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const { data: agent, isLoading } = useQuery({
    queryKey: ['agent', id],
    queryFn: () => api.get<Agent>(`/agents/${id}`),
    enabled: !!id,
  });

  const { data: allTasks } = useQuery({
    queryKey: ['tasks'],
    queryFn: () => api.get<Task[]>('/tasks'),
  });

  const { data: costsByAgent } = useQuery({
    queryKey: ['costs-by-agent'],
    queryFn: () => api.get<CostByAgent[]>('/costs/by-agent'),
  });

  const { data: activity } = useQuery({
    queryKey: ['activity', id],
    queryFn: () => api.get<ActivityEntry[]>(`/activity?agentId=${id}&limit=20`),
    enabled: !!id,
  });

  const agentTasks = (allTasks ?? []).filter((t) => (t as any).agentId === id).slice(0, 10);
  const cost = (costsByAgent ?? []).find((c) => c.agentId === id);
  const adapter = adapterIcons[agent?.adapterType ?? ''] ?? { icon: '?', color: '#888' };
  const statusStyle = statusColors[agent?.status ?? ''] ?? statusColors.idle;

  if (isLoading) {
    return <div style={{ padding: '24px 28px', color: 'var(--text2)' }}>Loading...</div>;
  }

  if (!agent) {
    return <div style={{ padding: '24px 28px', color: 'var(--text2)' }}>Agent not found.</div>;
  }

  const heartbeatAge = agent.lastHeartbeat ? Date.now() - new Date(agent.lastHeartbeat).getTime() : null;
  const heartbeatHealthy = heartbeatAge !== null && heartbeatAge < 60_000;

  return (
    <div style={{ padding: '24px 28px' }}>
      {/* Header */}
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', gap: 12 }}>
        <button
          onClick={() => navigate('/agents')}
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
          Back
        </button>
        <div
          style={{
            width: 36,
            height: 36,
            borderRadius: 8,
            background: `linear-gradient(135deg, ${adapter.color}, ${adapter.color}88)`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 14,
            fontWeight: 700,
            color: '#fff',
          }}
        >
          {adapter.icon}
        </div>
        <div>
          <h1 style={{ fontSize: 20, fontWeight: 700 }}>{agent.name}</h1>
          <div style={{ fontSize: 12, color: 'var(--text2)', marginTop: 2 }}>{agent.adapterType.replace(/_/g, ' ')}</div>
        </div>
        <span
          style={{
            marginLeft: 'auto',
            padding: '4px 12px',
            borderRadius: 8,
            fontSize: 12,
            fontWeight: 600,
            background: statusStyle.bg,
            color: statusStyle.color,
          }}
        >
          {agent.status}
        </span>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
        {/* Agent Info */}
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
          <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 12 }}>Agent Info</div>
          <InfoRow label="Name" value={agent.name} />
          <InfoRow label="Adapter" value={agent.adapterType} />
          <InfoRow label="Status" value={agent.status} />
          <InfoRow label="Project ID" value={agent.projectId} />
          <InfoRow label="Created" value={new Date(agent.createdAt).toLocaleString()} />
          {Object.keys(agent.config ?? {}).length > 0 && (
            <div style={{ padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
              <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 6 }}>Config</div>
              <pre style={{ fontSize: 11, color: 'var(--text)', background: 'var(--surface2)', borderRadius: 6, padding: 8, margin: 0, overflow: 'auto', maxHeight: 120 }}>
                {JSON.stringify(agent.config, null, 2)}
              </pre>
            </div>
          )}
        </div>

        {/* Heartbeat & Cost */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {/* Heartbeat */}
          <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
            <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 12 }}>Heartbeat</div>
            {agent.lastHeartbeat ? (
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <div
                  style={{
                    width: 10,
                    height: 10,
                    borderRadius: '50%',
                    background: heartbeatHealthy ? 'var(--green)' : 'var(--red)',
                    flexShrink: 0,
                  }}
                />
                <div>
                  <div style={{ fontSize: 13, fontWeight: 500 }}>
                    {heartbeatHealthy ? 'Healthy' : 'Stale'}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2 }}>
                    Last seen {formatRelativeTime(agent.lastHeartbeat)}
                  </div>
                </div>
              </div>
            ) : (
              <div style={{ fontSize: 13, color: 'var(--text2)' }}>No heartbeat recorded</div>
            )}
          </div>

          {/* Cost */}
          <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
            <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 12 }}>Cost & Tokens</div>
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
              <div style={{ fontSize: 13, color: 'var(--text2)' }}>No cost data yet</div>
            )}
          </div>
        </div>

        {/* Task History */}
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
          <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
            Task History ({agentTasks.length})
          </div>
          <div style={{ padding: '8px 18px' }}>
            {agentTasks.length === 0 ? (
              <div style={{ padding: 16, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No tasks</div>
            ) : agentTasks.map((task) => {
              const s = taskStatusStyle[task.status] ?? taskStatusStyle.todo;
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

        {/* Recent Activity */}
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
          <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
            Recent Activity
          </div>
          <div style={{ padding: '8px 18px' }}>
            {(activity ?? []).length === 0 ? (
              <div style={{ padding: 16, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No activity</div>
            ) : (activity ?? []).map((entry) => (
              <div
                key={entry.id}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '8px 0',
                  borderBottom: '1px solid var(--border)',
                }}
              >
                <span style={{ fontSize: 12, color: 'var(--text)', flex: 1 }}>{entry.eventType}</span>
                <span style={{ fontSize: 11, color: 'var(--text2)', whiteSpace: 'nowrap', marginLeft: 8 }}>
                  {formatRelativeTime(entry.createdAt)}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
