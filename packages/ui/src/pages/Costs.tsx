import { useQuery } from '@tanstack/react-query';
import { api } from '../api/client.js';

interface CostSummary { totalUsd: number; tokensIn: number; tokensOut: number; }
interface CostByAgent { agentId: string; agentName: string; adapterType: string; totalUsd: number; tokensIn: number; tokensOut: number; }
interface CostDaily { date: string; totalUsd: number; tokensIn: number; tokensOut: number; }

function formatUsd(n: number) { return `$${n.toFixed(2)}`; }
function formatTokens(n: number) { return n >= 1000000 ? `${(n / 1000000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(0)}K` : String(n); }

export function Costs() {
  const { data: summary } = useQuery({ queryKey: ['costs-summary'], queryFn: () => api.get<CostSummary>('/costs/summary') });
  const { data: byAgent } = useQuery({ queryKey: ['costs-by-agent'], queryFn: () => api.get<CostByAgent[]>('/costs/by-agent') });
  const { data: daily } = useQuery({ queryKey: ['costs-daily'], queryFn: () => api.get<CostDaily[]>('/costs/daily?days=14') });

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Costs</h1>
      </div>

      {/* Summary Cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 16, marginBottom: 24 }}>
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
          <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 8 }}>Monthly Spend</div>
          <div style={{ fontSize: 28, fontWeight: 700 }}>{formatUsd(summary?.totalUsd ?? 0)}</div>
        </div>
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
          <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 8 }}>Input Tokens</div>
          <div style={{ fontSize: 28, fontWeight: 700 }}>{formatTokens(summary?.tokensIn ?? 0)}</div>
        </div>
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, padding: 18 }}>
          <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 8 }}>Output Tokens</div>
          <div style={{ fontSize: 28, fontWeight: 700 }}>{formatTokens(summary?.tokensOut ?? 0)}</div>
        </div>
      </div>

      {/* By Agent */}
      <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, marginBottom: 24 }}>
        <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>Cost by Agent</div>
        <div style={{ padding: '8px 18px' }}>
          {(byAgent ?? []).length === 0 ? (
            <div style={{ padding: 20, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No cost data yet</div>
          ) : (byAgent ?? []).map((a) => (
            <div key={a.agentId} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
              <div>
                <div style={{ fontSize: 13, fontWeight: 500 }}>{a.agentName}</div>
                <div style={{ fontSize: 11, color: 'var(--text2)' }}>{a.adapterType}</div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div style={{ fontSize: 13, fontWeight: 600 }}>{formatUsd(a.totalUsd)}</div>
                <div style={{ fontSize: 10, color: 'var(--text2)' }}>{formatTokens(a.tokensIn)} in / {formatTokens(a.tokensOut)} out</div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Daily Chart (simple bar representation) */}
      <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
        <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>Daily Spend (14 days)</div>
        <div style={{ padding: 18 }}>
          {(daily ?? []).length === 0 ? (
            <div style={{ padding: 20, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No daily data yet</div>
          ) : (
            <div style={{ display: 'flex', alignItems: 'flex-end', gap: 4, height: 120 }}>
              {(daily ?? []).map((d) => {
                const maxUsd = Math.max(...(daily ?? []).map(x => x.totalUsd), 1);
                const height = Math.max((d.totalUsd / maxUsd) * 100, 4);
                return (
                  <div key={d.date} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
                    <div style={{ width: '100%', height, background: 'var(--accent)', borderRadius: '3px 3px 0 0', minHeight: 4 }} title={`${d.date}: ${formatUsd(d.totalUsd)}`} />
                    <span style={{ fontSize: 8, color: 'var(--text2)' }}>{d.date.slice(5)}</span>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
