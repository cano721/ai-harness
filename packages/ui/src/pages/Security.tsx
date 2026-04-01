import { useQuery } from '@tanstack/react-query';
import { api } from '../api/client.js';

interface ActivityEntry {
  id: string;
  projectId?: string;
  agentId?: string;
  eventType: string;
  detail: Record<string, unknown>;
  createdAt: string;
  agentName?: string;
  projectName?: string;
}

const eventIcons: Record<string, { icon: string; bg: string; color: string }> = {
  'security.blocked': { icon: '✕', bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
  'security.warning': { icon: '!', bg: 'rgba(254,202,87,0.1)', color: 'var(--yellow)' },
};

export function Security() {
  const { data: events, isLoading } = useQuery({ queryKey: ['security'], queryFn: () => api.get<ActivityEntry[]>('/activity/security') });
  const { data: counts } = useQuery({ queryKey: ['activity-counts'], queryFn: () => api.get<any>('/activity/counts') });

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <h1 style={{ fontSize: 20, fontWeight: 700 }}>Security Events</h1>
          <p style={{ fontSize: 13, color: 'var(--text2)', marginTop: 4 }}>Blocked and warned actions by guardrails</p>
        </div>
        <div style={{ padding: '8px 16px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 10, textAlign: 'center' }}>
          <div style={{ fontSize: 24, fontWeight: 700, color: 'var(--red)' }}>{counts?.securityEventsToday ?? 0}</div>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>today</div>
        </div>
      </div>

      {isLoading ? <div style={{ color: 'var(--text2)' }}>Loading...</div> : (events ?? []).length === 0 ? (
        <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
          <div style={{ fontSize: 32, marginBottom: 8 }}>🛡</div>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--green)' }}>All clear</div>
          <div style={{ fontSize: 13, marginTop: 4 }}>No security events recorded.</div>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {(events ?? []).map((event) => {
            const ei = eventIcons[event.eventType] ?? { icon: 'i', bg: 'rgba(116,185,255,0.1)', color: 'var(--blue)' };
            return (
              <div key={event.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 10, padding: '12px 18px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 10 }}>
                <div style={{ width: 24, height: 24, borderRadius: 6, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, background: ei.bg, color: ei.color, flexShrink: 0 }}>{ei.icon}</div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 12 }}>
                    {event.agentName && <span style={{ color: 'var(--accent2)', fontWeight: 500 }}>{event.agentName}</span>}
                    {' — '}{String(event.detail.message ?? event.eventType)}
                  </div>
                  <div style={{ fontSize: 10, color: 'var(--text2)', marginTop: 4 }}>{new Date(event.createdAt).toLocaleString()}{event.projectName ? ` · ${event.projectName}` : ''}</div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
