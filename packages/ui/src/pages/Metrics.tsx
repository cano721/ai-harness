import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client.js';

interface AgentMetric {
  agentId: string;
  agentName: string;
  adapterType: string;
  totalRuns: number;
  successRuns: number;
  successRate: number;
  avgDurationSec: number;
  totalCostUsd: number;
  costPerTask: number;
}

interface ProjectMetric {
  projectId: string;
  projectName: string;
  totalTasks: number;
  doneTasks: number;
  inProgressTasks: number;
  completionRate: number;
  totalCostUsd: number;
}

interface SystemMetric {
  totalAgents: number;
  runningAgents: number;
  idleAgents: number;
  utilizationRate: number;
  totalTaskRuns: number;
  totalCostUsd: number;
  avgSuccessRate: number;
}

type Tab = 'system' | 'agents' | 'projects';

function pct(n: number) {
  return `${(n * 100).toFixed(1)}%`;
}

function usd(n: number) {
  return `$${n.toFixed(4)}`;
}

function sec(n: number) {
  if (n >= 60) return `${(n / 60).toFixed(1)}m`;
  return `${n}s`;
}

function BarCell({ value, max }: { value: number; max: number }) {
  const pct = max > 0 ? (value / max) * 100 : 0;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <div style={{ flex: 1, height: 6, background: 'var(--surface3)', borderRadius: 3, overflow: 'hidden' }}>
        <div style={{ width: `${pct}%`, height: '100%', background: 'var(--accent)', borderRadius: 3 }} />
      </div>
      <span style={{ fontSize: 11, color: 'var(--text2)', width: 36, textAlign: 'right' }}>{pct.toFixed(0)}%</span>
    </div>
  );
}

function StatCard({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
      <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 6 }}>{label}</div>
      <div style={{ fontSize: 24, fontWeight: 700 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

function SystemTab({ data }: { data: SystemMetric }) {
  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Total Agents" value={String(data.totalAgents)} sub={`${data.runningAgents} running / ${data.idleAgents} idle`} />
        <StatCard label="Utilization" value={pct(data.utilizationRate)} sub="agents running now" />
        <StatCard label="Total Task Runs" value={String(data.totalTaskRuns)} />
        <StatCard label="Overall Success Rate" value={pct(data.avgSuccessRate)} />
        <StatCard label="Total Cost" value={usd(data.totalCostUsd)} />
      </div>

      <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
        <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 12 }}>Agent Utilization</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 13, color: 'var(--text2)', width: 80 }}>Running</span>
            <div style={{ flex: 1, marginLeft: 12 }}>
              <BarCell value={data.runningAgents} max={data.totalAgents} />
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 13, color: 'var(--text2)', width: 80 }}>Idle</span>
            <div style={{ flex: 1, marginLeft: 12 }}>
              <BarCell value={data.idleAgents} max={data.totalAgents} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function AgentsTab({ data }: { data: AgentMetric[] }) {
  if (data.length === 0) {
    return <div style={{ padding: 40, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No agent run data yet</div>;
  }

  const maxRuns = Math.max(...data.map(a => a.totalRuns), 1);

  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, overflow: 'hidden' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
        <thead>
          <tr style={{ borderBottom: '1px solid var(--border)' }}>
            {['Agent', 'Adapter', 'Runs', 'Success Rate', 'Avg Duration', 'Total Cost', 'Cost/Task'].map(h => (
              <th key={h} style={{ padding: '10px 16px', textAlign: 'left', fontSize: 11, color: 'var(--text2)', fontWeight: 600 }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.map(a => (
            <tr key={a.agentId} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ padding: '10px 16px', fontWeight: 500 }}>{a.agentName}</td>
              <td style={{ padding: '10px 16px', color: 'var(--text2)' }}>{a.adapterType.replace('_', ' ')}</td>
              <td style={{ padding: '10px 16px' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <span>{a.totalRuns}</span>
                  <BarCell value={a.totalRuns} max={maxRuns} />
                </div>
              </td>
              <td style={{ padding: '10px 16px' }}>
                <span style={{ color: a.successRate >= 0.8 ? 'var(--green)' : a.successRate >= 0.5 ? 'var(--yellow)' : 'var(--red)' }}>
                  {pct(a.successRate)}
                </span>
              </td>
              <td style={{ padding: '10px 16px', color: 'var(--text2)' }}>{sec(a.avgDurationSec)}</td>
              <td style={{ padding: '10px 16px' }}>{usd(a.totalCostUsd)}</td>
              <td style={{ padding: '10px 16px', color: 'var(--text2)' }}>{usd(a.costPerTask)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ProjectsTab({ data }: { data: ProjectMetric[] }) {
  if (data.length === 0) {
    return <div style={{ padding: 40, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No project task data yet</div>;
  }

  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, overflow: 'hidden' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
        <thead>
          <tr style={{ borderBottom: '1px solid var(--border)' }}>
            {['Project', 'Total Tasks', 'Done', 'In Progress', 'Completion', 'Total Cost'].map(h => (
              <th key={h} style={{ padding: '10px 16px', textAlign: 'left', fontSize: 11, color: 'var(--text2)', fontWeight: 600 }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.map(p => (
            <tr key={p.projectId} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ padding: '10px 16px', fontWeight: 500 }}>{p.projectName}</td>
              <td style={{ padding: '10px 16px' }}>{p.totalTasks}</td>
              <td style={{ padding: '10px 16px', color: 'var(--green)' }}>{p.doneTasks}</td>
              <td style={{ padding: '10px 16px', color: 'var(--blue)' }}>{p.inProgressTasks}</td>
              <td style={{ padding: '10px 16px' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <span>{pct(p.completionRate)}</span>
                  <div style={{ height: 4, background: 'var(--surface3)', borderRadius: 2, overflow: 'hidden', width: 80 }}>
                    <div style={{ width: `${p.completionRate * 100}%`, height: '100%', background: 'var(--green)', borderRadius: 2 }} />
                  </div>
                </div>
              </td>
              <td style={{ padding: '10px 16px' }}>{usd(p.totalCostUsd)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Metrics() {
  const [tab, setTab] = useState<Tab>('system');

  const { data: systemData } = useQuery({ queryKey: ['metrics-system'], queryFn: () => api.get<SystemMetric>('/metrics/system') });
  const { data: agentData } = useQuery({ queryKey: ['metrics-agents'], queryFn: () => api.get<AgentMetric[]>('/metrics/agents') });
  const { data: projectData } = useQuery({ queryKey: ['metrics-projects'], queryFn: () => api.get<ProjectMetric[]>('/metrics/projects') });

  const tabs: { key: Tab; label: string }[] = [
    { key: 'system', label: 'System' },
    { key: 'agents', label: 'Agents' },
    { key: 'projects', label: 'Projects' },
  ];

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Metrics</h1>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 4, marginBottom: 20, borderBottom: '1px solid var(--border)', paddingBottom: 0 }}>
        {tabs.map(t => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            style={{
              padding: '8px 16px',
              border: 'none',
              background: 'transparent',
              color: tab === t.key ? 'var(--accent2)' : 'var(--text2)',
              fontSize: 13,
              fontWeight: tab === t.key ? 600 : 400,
              cursor: 'pointer',
              borderBottom: tab === t.key ? '2px solid var(--accent2)' : '2px solid transparent',
              marginBottom: -1,
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === 'system' && systemData && <SystemTab data={systemData} />}
      {tab === 'system' && !systemData && <div style={{ color: 'var(--text2)' }}>Loading...</div>}
      {tab === 'agents' && <AgentsTab data={agentData ?? []} />}
      {tab === 'projects' && <ProjectsTab data={projectData ?? []} />}
    </div>
  );
}
