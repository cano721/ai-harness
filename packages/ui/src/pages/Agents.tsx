import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client.js';

interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: string;
  status: string;
  lastHeartbeat?: string;
  createdAt: string;
}

const statusColors: Record<string, { bg: string; color: string }> = {
  running: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  idle: { bg: 'var(--surface3)', color: 'var(--text2)' },
  paused: { bg: 'rgba(254,202,87,0.1)', color: 'var(--yellow)' },
  error: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
  terminated: { bg: 'var(--surface3)', color: 'var(--text2)' },
};

const adapterIcons: Record<string, { icon: string; color: string }> = {
  claude_local: { icon: 'C', color: '#d4a574' },
  codex_local: { icon: 'X', color: '#74b9ff' },
  cursor_local: { icon: 'Cu', color: '#a29bfe' },
};

export function Agents() {
  const { data: agents, isLoading } = useQuery({ queryKey: ['agents'], queryFn: () => api.get<Agent[]>('/agents') });

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Agents</h1>
      </div>

      {isLoading ? <div style={{ color: 'var(--text2)' }}>Loading...</div> : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {(agents ?? []).length === 0 ? (
            <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
              <div style={{ fontSize: 32, marginBottom: 8 }}>🤖</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>No agents yet</div>
              <div style={{ fontSize: 13, marginTop: 4 }}>Agents are created when you run tasks.</div>
            </div>
          ) : (agents ?? []).map((agent) => {
            const adapter = adapterIcons[agent.adapterType] ?? { icon: '?', color: '#888' };
            const status = statusColors[agent.status] ?? statusColors.idle;
            return (
              <div key={agent.id} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 18px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
                <div style={{ width: 36, height: 36, borderRadius: 8, background: `linear-gradient(135deg, ${adapter.color}, ${adapter.color}88)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, color: '#fff' }}>{adapter.icon}</div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 13, fontWeight: 600 }}>{agent.name}</div>
                  <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2 }}>{agent.adapterType.replace('_', ' ')}</div>
                </div>
                <span style={{ padding: '3px 10px', borderRadius: 6, fontSize: 11, fontWeight: 600, background: status.bg, color: status.color }}>● {agent.status}</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
