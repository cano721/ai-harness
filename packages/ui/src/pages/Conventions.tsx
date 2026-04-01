import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client.js';

interface Convention {
  id: string;
  projectId: string;
  scope: string;
  category: string;
  rule: string;
  enabled: boolean;
  createdAt: string;
}

interface Project {
  id: string;
  name: string;
}

const scopeColors: Record<string, string> = { global: 'var(--accent)', project: 'var(--green)', repo: 'var(--yellow)' };

export function Conventions() {
  const queryClient = useQueryClient();
  const { data: projects } = useQuery({ queryKey: ['projects'], queryFn: () => api.get<Project[]>('/projects') });
  const [selectedProject, setSelectedProject] = useState<string>('');
  const projectId = selectedProject || projects?.[0]?.id || '';

  const { data: conventions, isLoading } = useQuery({
    queryKey: ['conventions', projectId],
    queryFn: () => projectId ? api.get<Convention[]>(`/conventions/${projectId}`) : Promise.resolve([]),
    enabled: !!projectId,
  });

  const [showAdd, setShowAdd] = useState(false);
  const [category, setCategory] = useState('');
  const [rule, setRule] = useState('');
  const [scope, setScope] = useState('project');

  const addMutation = useMutation({
    mutationFn: () => api.post(`/conventions/${projectId}`, { category, rule, scope }),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['conventions'] }); setShowAdd(false); setCategory(''); setRule(''); },
  });

  const toggleMutation = useMutation({
    mutationFn: (conv: Convention) => api.patch(`/conventions/${projectId}/${conv.id}`, { enabled: !conv.enabled }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['conventions'] }),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: string) => api.delete(`/conventions/${projectId}/${id}`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['conventions'] }),
  });

  const inputStyle = { padding: '8px 12px', background: 'var(--surface3)', border: '1px solid var(--border)', borderRadius: 8, color: 'var(--text)', fontSize: 13, outline: 'none' } as const;

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Conventions</h1>
        <div style={{ display: 'flex', gap: 8 }}>
          <select value={selectedProject} onChange={(e) => setSelectedProject(e.target.value)} style={{ ...inputStyle, minWidth: 150 }}>
            {(projects ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
          <button onClick={() => setShowAdd(!showAdd)} style={{ padding: '7px 14px', borderRadius: 8, border: '1px solid var(--accent)', background: 'var(--accent)', color: '#fff', fontSize: 12, cursor: 'pointer' }}>+ Add Rule</button>
        </div>
      </div>

      {showAdd && (
        <div style={{ padding: 16, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, marginBottom: 16, display: 'flex', gap: 8, alignItems: 'flex-end' }}>
          <div style={{ flex: 1 }}>
            <label style={{ fontSize: 11, color: 'var(--text2)', display: 'block', marginBottom: 4 }}>Category</label>
            <input style={{ ...inputStyle, width: '100%' }} value={category} onChange={(e) => setCategory(e.target.value)} placeholder="code-style" />
          </div>
          <div style={{ flex: 2 }}>
            <label style={{ fontSize: 11, color: 'var(--text2)', display: 'block', marginBottom: 4 }}>Rule</label>
            <input style={{ ...inputStyle, width: '100%' }} value={rule} onChange={(e) => setRule(e.target.value)} placeholder="no-force-push" />
          </div>
          <select value={scope} onChange={(e) => setScope(e.target.value)} style={inputStyle}>
            <option value="global">Global</option>
            <option value="project">Project</option>
            <option value="repo">Repo</option>
          </select>
          <button onClick={() => addMutation.mutate()} disabled={!category || !rule} style={{ padding: '8px 16px', borderRadius: 8, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 12, cursor: category && rule ? 'pointer' : 'not-allowed', opacity: category && rule ? 1 : 0.5, whiteSpace: 'nowrap' }}>Add</button>
        </div>
      )}

      {!projectId ? (
        <div style={{ color: 'var(--text2)', textAlign: 'center', padding: 40 }}>Create a project first.</div>
      ) : isLoading ? (
        <div style={{ color: 'var(--text2)' }}>Loading...</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {(conventions ?? []).length === 0 ? (
            <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
              <div style={{ fontSize: 32, marginBottom: 8 }}>📐</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>No conventions yet</div>
            </div>
          ) : (conventions ?? []).map((conv) => (
            <div key={conv.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 10 }}>
              <div style={{ width: 6, height: 6, borderRadius: '50%', background: scopeColors[conv.scope] ?? 'var(--text2)' }} />
              <span style={{ fontSize: 12, color: 'var(--text2)', minWidth: 80 }}>{conv.category}</span>
              <span style={{ fontSize: 12, fontFamily: "'SF Mono', monospace", flex: 1 }}>{conv.rule}</span>
              <span style={{ fontSize: 10, color: 'var(--text2)' }}>{conv.scope}</span>
              <button onClick={() => toggleMutation.mutate(conv)} style={{ padding: '3px 8px', borderRadius: 4, border: '1px solid var(--border)', background: conv.enabled ? 'var(--green)' : 'var(--surface3)', color: conv.enabled ? '#fff' : 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>{conv.enabled ? 'ON' : 'OFF'}</button>
              <button onClick={() => deleteMutation.mutate(conv.id)} style={{ padding: '3px 8px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface3)', color: 'var(--red)', fontSize: 10, cursor: 'pointer' }}>x</button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
