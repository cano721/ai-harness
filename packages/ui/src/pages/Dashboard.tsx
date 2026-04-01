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
    <div
      style={{
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 12,
        padding: 18,
      }}
    >
      <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 8 }}>{label}</div>
      <div style={{ fontSize: 28, fontWeight: 700, color: color ?? 'var(--text)' }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

export function Dashboard() {
  const { data, isLoading } = useQuery({ queryKey: ['dashboard'], queryFn: fetchDashboard });

  return (
    <div style={{ padding: '24px 28px' }}>
      <div
        style={{
          padding: '16px 0 24px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
        }}
      >
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Dashboard</h1>
      </div>

      {isLoading ? (
        <div style={{ color: 'var(--text2)' }}>Loading...</div>
      ) : (
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(4, 1fr)',
            gap: 16,
          }}
        >
          <MetricCard
            label="🤖 Active Agents"
            value={String(data?.activeAgents ?? 0)}
            sub={`${data?.runningAgents ?? 0} running now`}
            color="var(--green)"
          />
          <MetricCard
            label="📐 Convention Compliance"
            value={`${data?.conventionCompliance ?? 0}%`}
            color="var(--text)"
          />
          <MetricCard
            label="🛡 Security Events"
            value={String(data?.securityEvents ?? 0)}
            color="var(--red)"
          />
          <MetricCard
            label="💰 Monthly Cost"
            value={`$${data?.monthlyCostUsd ?? 0}`}
            sub={`/ $${data?.monthlyBudgetUsd ?? 300} budget`}
          />
        </div>
      )}

      <div
        style={{
          marginTop: 32,
          padding: 40,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 12,
          textAlign: 'center',
          color: 'var(--text2)',
        }}
      >
        <div style={{ fontSize: 48, marginBottom: 12 }}>⚡</div>
        <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--text)', marginBottom: 8 }}>
          Ddalkak is running
        </div>
        <div style={{ fontSize: 13 }}>
          Connect a project to get started. Go to Projects → Add Project.
        </div>
      </div>
    </div>
  );
}
