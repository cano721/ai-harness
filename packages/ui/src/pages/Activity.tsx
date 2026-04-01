import { useQuery } from '@tanstack/react-query';
import { api } from '../api/client.js';

interface ActivityEntry {
  id: string;
  eventType: string;
  detail: Record<string, unknown>;
  createdAt: string;
  agentName?: string;
  projectName?: string;
}

const typeColors: Record<string, string> = {
  'task.started': 'var(--blue)',
  'task.completed': 'var(--green)',
  'task.failed': 'var(--red)',
  'security.blocked': 'var(--red)',
  'security.warning': 'var(--yellow)',
};

export function Activity() {
  const { data: events, isLoading } = useQuery({ queryKey: ['activity'], queryFn: () => api.get<ActivityEntry[]>('/activity?limit=100') });

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Audit Log</h1>
        <p style={{ fontSize: 13, color: 'var(--text2)', marginTop: 4 }}>All agent activity and system events</p>
      </div>

      {isLoading ? <div style={{ color: 'var(--text2)' }}>Loading...</div> : (events ?? []).length === 0 ? (
        <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
          <div style={{ fontSize: 32, marginBottom: 8 }}>📝</div>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>No activity yet</div>
        </div>
      ) : (
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, overflow: 'hidden' }}>
          {(events ?? []).map((event, i) => (
            <div key={event.id} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 18px', borderBottom: i < (events?.length ?? 0) - 1 ? '1px solid var(--border)' : 'none' }}>
              <div style={{ width: 8, height: 8, borderRadius: '50%', background: typeColors[event.eventType] ?? 'var(--text2)', flexShrink: 0 }} />
              <span style={{ fontSize: 11, color: 'var(--text2)', minWidth: 120, fontFamily: "'SF Mono', monospace" }}>{event.eventType}</span>
              <span style={{ fontSize: 12, flex: 1 }}>
                {event.agentName && <span style={{ color: 'var(--accent2)' }}>{event.agentName} </span>}
                {String(event.detail.title ?? event.detail.message ?? '')}
              </span>
              <span style={{ fontSize: 10, color: 'var(--text2)', whiteSpace: 'nowrap' }}>{new Date(event.createdAt).toLocaleString()}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
