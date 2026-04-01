import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client.js';

interface Task {
  id: string;
  projectId: string;
  agentId?: string;
  title: string;
  description?: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}

const statusStyle: Record<string, { bg: string; color: string }> = {
  todo: { bg: 'var(--surface3)', color: 'var(--text2)' },
  in_progress: { bg: 'rgba(116,185,255,0.1)', color: 'var(--blue)' },
  done: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  blocked: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

export function Tasks() {
  const queryClient = useQueryClient();
  const { data: tasks, isLoading } = useQuery({ queryKey: ['tasks'], queryFn: () => api.get<Task[]>('/tasks') });
  const [showCreate, setShowCreate] = useState(false);
  const [title, setTitle] = useState('');
  const [projectId, setProjectId] = useState('');
  const { data: projects } = useQuery({ queryKey: ['projects'], queryFn: () => api.get<any[]>('/projects') });

  const createMutation = useMutation({
    mutationFn: () => api.post('/tasks', { projectId: projectId || (projects?.[0]?.id), title }),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['tasks'] }); setShowCreate(false); setTitle(''); },
  });

  const inputStyle = { width: '100%', padding: '8px 12px', background: 'var(--surface3)', border: '1px solid var(--border)', borderRadius: 8, color: 'var(--text)', fontSize: 13, outline: 'none' } as const;

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Tasks</h1>
        <button onClick={() => setShowCreate(!showCreate)} style={{ padding: '7px 14px', borderRadius: 8, border: '1px solid var(--accent)', background: 'var(--accent)', color: '#fff', fontSize: 12, cursor: 'pointer' }}>+ New Task</button>
      </div>

      {showCreate && (
        <div style={{ padding: 16, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, marginBottom: 16 }}>
          <input style={inputStyle} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Task description..." />
          <div style={{ display: 'flex', gap: 8, marginTop: 8, justifyContent: 'flex-end' }}>
            <button onClick={() => setShowCreate(false)} style={{ padding: '6px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12, cursor: 'pointer' }}>Cancel</button>
            <button onClick={() => createMutation.mutate()} disabled={!title} style={{ padding: '6px 12px', borderRadius: 6, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 12, cursor: title ? 'pointer' : 'not-allowed', opacity: title ? 1 : 0.5 }}>Create</button>
          </div>
        </div>
      )}

      {isLoading ? <div style={{ color: 'var(--text2)' }}>Loading...</div> : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {(tasks ?? []).length === 0 ? (
            <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
              <div style={{ fontSize: 32, marginBottom: 8 }}>📋</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>No tasks yet</div>
            </div>
          ) : (tasks ?? []).map((task) => {
            const s = statusStyle[task.status] ?? statusStyle.todo;
            return (
              <div key={task.id} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 18px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 10 }}>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 13, fontWeight: 500 }}>{task.title}</div>
                  <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2 }}>{new Date(task.createdAt).toLocaleString()}</div>
                </div>
                <span style={{ padding: '3px 10px', borderRadius: 6, fontSize: 10, fontWeight: 600, background: s.bg, color: s.color }}>{task.status}</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
