import { useQuery } from '@tanstack/react-query';

interface DashboardSummary {
  activeAgents: number;
  runningAgents: number;
  conventionCompliance: number;
  securityEvents: number;
  monthlyCostUsd: number;
  monthlyBudgetUsd: number;
}

async function fetchDashboard(): Promise<DashboardSummary> {
  const res = await fetch('/api/dashboard');
  const json = await res.json();
  return json.data;
}

function MetricCard({ label, value, sub, color }: { label: string; value: string; sub?: string; color?: string }) {
  return (
    <div className="metric-card">
      <div className="metric-label">{label}</div>
      <div className="metric-value" style={{ color: color ?? 'var(--text)' }}>{value}</div>
      {sub && <div className="metric-sub">{sub}</div>}
    </div>
  );
}

export function Dashboard() {
  const { data, isLoading } = useQuery({ queryKey: ['dashboard'], queryFn: fetchDashboard });
  const budgetRatio = data && data.monthlyBudgetUsd > 0
    ? Math.min(100, Math.round((data.monthlyCostUsd / data.monthlyBudgetUsd) * 100))
    : 0;

  return (
    <div className="page-shell">
      <div className="page-hero">
        <div>
          <span className="page-eyebrow">Overview</span>
          <h1>Operate AI agents with visible guardrails</h1>
          <p>
            Ddalkak sits between local runtimes and project conventions so teams can start fast,
            keep boundaries explicit, and track agent activity from one dashboard.
          </p>
        </div>
        <div className="hero-panel">
          <div className="hero-panel-label">This workspace</div>
          <strong>Monorepo control plane</strong>
          <p>Hooks enforce safety. Teams define conventions. Adapters connect Claude, Codex, and Cursor.</p>
        </div>
      </div>

      {isLoading ? (
        <div style={{ color: 'var(--text2)' }}>Loading...</div>
      ) : (
        <div className="metric-grid">
          <MetricCard
            label="Active Agents"
            value={String(data?.activeAgents ?? 0)}
            sub={`${data?.runningAgents ?? 0} running now`}
            color="var(--green)"
          />
          <MetricCard
            label="Convention Compliance"
            value={`${data?.conventionCompliance ?? 0}%`}
            color="var(--text)"
          />
          <MetricCard
            label="Security Events"
            value={String(data?.securityEvents ?? 0)}
            color="var(--red)"
          />
          <MetricCard
            label="Monthly Cost"
            value={`$${data?.monthlyCostUsd ?? 0}`}
            sub={`/ $${data?.monthlyBudgetUsd ?? 300} budget`}
          />
        </div>
      )}

      <div className="dashboard-grid">
        <section className="panel-card">
          <div className="panel-card-header">
            <div>
              <span className="page-eyebrow">Architecture</span>
              <h2>Control plane stack</h2>
            </div>
          </div>
          <div className="stack-list">
            <div className="stack-row">
              <strong>UI</strong>
              <span>React + Vite workspace for projects, agents, tasks, and metrics.</span>
            </div>
            <div className="stack-row">
              <strong>API</strong>
              <span>Express routes aggregate adapters, services, and governance state.</span>
            </div>
            <div className="stack-row">
              <strong>Data</strong>
              <span>Shared types and database packages define a stable control-plane contract.</span>
            </div>
            <div className="stack-row">
              <strong>Adapters</strong>
              <span>Local runtimes execute work while Ddalkak tracks status, cost, and heartbeats.</span>
            </div>
          </div>
        </section>

        <section className="panel-card">
          <div className="panel-card-header">
            <div>
              <span className="page-eyebrow">Budget</span>
              <h2>Spend pacing</h2>
            </div>
          </div>
          <div className="budget-stat">
            <strong>{budgetRatio}%</strong>
            <span>of monthly budget consumed</span>
          </div>
          <div className="progress-track">
            <div className="progress-fill" style={{ width: `${budgetRatio}%` }} />
          </div>
          <p className="panel-copy">
            Use costs and heartbeat history together to identify which adapters should stay always-on
            versus heartbeat-driven.
          </p>
        </section>
      </div>

      <div className="panel-card panel-callout">
        <div className="panel-card-header">
          <div>
            <span className="page-eyebrow">Next step</span>
            <h2>Connect a project and let the control plane populate</h2>
          </div>
        </div>
        <p className="panel-copy">
          Start from Projects, analyze a repository path, and Ddalkak will surface detected tech stack,
          installed CLIs, conventions, hooks, and adapter readiness.
        </p>
      </div>
    </div>
  );
}
