import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { api } from '../api/client.js';

interface AgentSettings {
  type: string;
  installed: boolean;
  version?: string;
  configPath?: string;
  settings: Record<string, unknown>;
  hooks?: string[];
  skills?: string[];
  mcpServers?: string[];
}

async function fetchSettings(): Promise<AgentSettings[]> {
  const res = await fetch('/api/settings');
  const json = await res.json();
  return json.data;
}

const adapterMeta: Record<string, { name: string; color: string; icon: string }> = {
  claude_local: { name: 'Claude Code', color: '#d4a574', icon: 'C' },
  codex_local: { name: 'Codex', color: '#74b9ff', icon: 'X' },
  cursor_local: { name: 'Cursor', color: '#a29bfe', icon: 'Cu' },
};

function Expandable({ label, count, children }: { label: string; count?: number; children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <div style={{ borderBottom: '1px solid var(--border)' }}>
      <div
        onClick={() => setOpen(!open)}
        style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0', cursor: 'pointer', userSelect: 'none' }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 10, color: 'var(--text2)', transition: 'transform 0.15s', transform: open ? 'rotate(90deg)' : 'none' }}>▶</span>
          <span style={{ fontSize: 13 }}>{label}</span>
        </div>
        {count !== undefined && (
          <span style={{ fontSize: 11, color: 'var(--text2)', background: 'var(--surface3)', padding: '1px 8px', borderRadius: 10 }}>{count}</span>
        )}
      </div>
      {open && <div style={{ paddingBottom: 12 }}>{children}</div>}
    </div>
  );
}

function JsonBlock({ data }: { data: unknown }) {
  return (
    <pre style={{
      background: 'var(--surface3)',
      borderRadius: 8,
      padding: 12,
      fontSize: 11,
      fontFamily: "'SF Mono', 'Fira Code', monospace",
      color: 'var(--text)',
      overflow: 'auto',
      maxHeight: 400,
      margin: 0,
      lineHeight: 1.6,
      whiteSpace: 'pre-wrap',
      wordBreak: 'break-word',
    }}>
      {JSON.stringify(data, null, 2)}
    </pre>
  );
}

function McpDetailList({ agentType, servers }: { agentType: string; servers: Record<string, any> }) {
  const [expanded, setExpanded] = useState<string | null>(null);
  const [showAdd, setShowAdd] = useState(false);
  const [newName, setNewName] = useState('');
  const [newCommand, setNewCommand] = useState('');
  const [newArgs, setNewArgs] = useState('');
  const [newEnv, setNewEnv] = useState('');
  const queryClient = useQueryClient();

  const [editing, setEditing] = useState<string | null>(null);
  const [editCommand, setEditCommand] = useState('');
  const [editArgs, setEditArgs] = useState('');
  const [editEnv, setEditEnv] = useState('');

  const [testResults, setTestResults] = useState<Record<string, { status: string; error?: string; loading?: boolean }>>({});

  const deleteMutation = useMutation({
    mutationFn: (name: string) => fetch(`/api/settings/${agentType}/mcp/${name}`, { method: 'DELETE' }).then(r => r.json()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['settings'] }),
  });

  // Auto-test all servers on mount
  useEffect(() => {
    if (Object.keys(servers).length === 0) return;
    const names = Object.keys(servers);
    names.forEach(n => setTestResults(prev => ({ ...prev, [n]: { status: 'testing', loading: true } })));

    fetch(`/api/settings/${agentType}/mcp-test-all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      .then(r => r.json())
      .then(json => {
        if (json.ok) {
          setTestResults(json.data);
        }
      })
      .catch(() => {});
  }, [agentType, Object.keys(servers).join(',')]);

  async function testConnection(name: string) {
    setTestResults(prev => ({ ...prev, [name]: { status: 'testing', loading: true } }));
    try {
      const res = await fetch(`/api/settings/${agentType}/mcp/${name}/test`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
      const json = await res.json();
      setTestResults(prev => ({ ...prev, [name]: json.data }));
    } catch {
      setTestResults(prev => ({ ...prev, [name]: { status: 'unreachable', error: 'Request failed' } }));
    }
  }

  const updateMutation = useMutation({
    mutationFn: (name: string) => {
      const envObj: Record<string, string> = {};
      if (editEnv.trim()) {
        editEnv.split('\n').forEach(line => {
          const [k, ...v] = line.split('=');
          if (k?.trim()) envObj[k.trim()] = v.join('=').trim();
        });
      }
      // Delete old, then add updated (MCP API is add-only, so re-create)
      return fetch(`/api/settings/${agentType}/mcp/${name}`, { method: 'DELETE' })
        .then(() => fetch(`/api/settings/${agentType}/mcp`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            name,
            command: editCommand,
            args: editArgs.trim() ? editArgs.trim().split(' ') : [],
            ...(Object.keys(envObj).length > 0 ? { env: envObj } : {}),
          }),
        }))
        .then(r => r.json());
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['settings'] });
      setEditing(null);
    },
  });

  function startEdit(name: string, config: any) {
    setEditing(name);
    setEditCommand(config.command ?? '');
    setEditArgs((config.args ?? []).join(' '));
    setEditEnv(config.env ? Object.entries(config.env).map(([k, v]) => `${k}=${v}`).join('\n') : '');
  }

  const addMutation = useMutation({
    mutationFn: () => {
      const envObj: Record<string, string> = {};
      if (newEnv.trim()) {
        newEnv.split('\n').forEach(line => {
          const [k, ...v] = line.split('=');
          if (k?.trim()) envObj[k.trim()] = v.join('=').trim();
        });
      }
      return fetch(`/api/settings/${agentType}/mcp`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: newName,
          command: newCommand,
          args: newArgs.trim() ? newArgs.trim().split(' ') : [],
          ...(Object.keys(envObj).length > 0 ? { env: envObj } : {}),
        }),
      }).then(r => r.json());
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['settings'] });
      setShowAdd(false);
      setNewName('');
      setNewCommand('');
      setNewArgs('');
      setNewEnv('');
    },
  });

  const inputStyle = { width: '100%', padding: '6px 10px', background: 'var(--bg)', border: '1px solid var(--border)', borderRadius: 6, color: 'var(--text)', fontSize: 11, fontFamily: "'SF Mono', monospace", outline: 'none' } as const;

  return (
    <div>
      {/* Add MCP form */}
      <div style={{ marginBottom: 8 }}>
        {showAdd ? (
          <div style={{ padding: 10, background: 'var(--surface3)', borderRadius: 8, marginBottom: 6 }}>
            <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Name</div>
                <input style={inputStyle} value={newName} onChange={e => setNewName(e.target.value)} placeholder="my-mcp" />
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Command</div>
                <input style={inputStyle} value={newCommand} onChange={e => setNewCommand(e.target.value)} placeholder="npx" />
              </div>
            </div>
            <div style={{ marginBottom: 6 }}>
              <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Args (space-separated)</div>
              <input style={inputStyle} value={newArgs} onChange={e => setNewArgs(e.target.value)} placeholder="-y @scope/mcp-server" />
            </div>
            <div style={{ marginBottom: 6 }}>
              <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Env (KEY=VALUE, one per line)</div>
              <textarea style={{ ...inputStyle, height: 50, resize: 'vertical' }} value={newEnv} onChange={e => setNewEnv(e.target.value)} placeholder={"MYSQL_HOST=localhost\nMYSQL_PORT=3306"} />
            </div>
            <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
              <button onClick={() => setShowAdd(false)} style={{ padding: '4px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>Cancel</button>
              <button onClick={() => addMutation.mutate()} disabled={!newName || !newCommand} style={{ padding: '4px 10px', borderRadius: 4, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: newName && newCommand ? 'pointer' : 'not-allowed', opacity: newName && newCommand ? 1 : 0.5 }}>Add Server</button>
            </div>
          </div>
        ) : (
          <button onClick={() => setShowAdd(true)} style={{ padding: '4px 10px', borderRadius: 4, border: '1px dashed var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 10, cursor: 'pointer', width: '100%' }}>+ Add MCP Server</button>
        )}
      </div>

      {Object.keys(servers).length === 0 && !showAdd && (
        <div style={{ textAlign: 'center', padding: 8, fontSize: 11, color: 'var(--text2)' }}>No MCP servers configured globally.</div>
      )}

      {Object.entries(servers).map(([name, config]) => (
        <div key={name} style={{ marginBottom: 4 }}>
          <div
            onClick={() => setExpanded(expanded === name ? null : name)}
            style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '6px 8px', background: 'var(--surface3)', borderRadius: 6, cursor: 'pointer', marginBottom: 2 }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 10, color: 'var(--text2)', transform: expanded === name ? 'rotate(90deg)' : 'none', transition: 'transform 0.15s' }}>▶</span>
              <span style={{ fontSize: 12, color: 'var(--blue)' }}>{name}</span>
              {testResults[name] && (
                <span style={{ fontSize: 10, fontWeight: 600, color: testResults[name].loading ? 'var(--text2)' : testResults[name].status === 'reachable' ? 'var(--green)' : 'var(--red)' }}>
                  {testResults[name].loading ? '...' : testResults[name].status === 'reachable' ? '● OK' : '✕ Failed'}
                </span>
              )}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 10, color: 'var(--text2)', fontFamily: "'SF Mono', monospace" }}>{config.command ?? 'unknown'}</span>
              <button onClick={(e) => { e.stopPropagation(); testConnection(name); }} style={{ padding: '2px 8px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 9, cursor: 'pointer' }}>Test</button>
            </div>
          </div>
          {expanded === name && (
            <div style={{ padding: '8px 12px', marginBottom: 4 }}>
              {editing === name ? (
                /* Edit mode */
                <div>
                  <div style={{ marginBottom: 6 }}>
                    <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Command</div>
                    <input style={inputStyle} value={editCommand} onChange={e => setEditCommand(e.target.value)} />
                  </div>
                  <div style={{ marginBottom: 6 }}>
                    <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Args (space-separated)</div>
                    <input style={inputStyle} value={editArgs} onChange={e => setEditArgs(e.target.value)} />
                  </div>
                  <div style={{ marginBottom: 6 }}>
                    <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 2 }}>Env (KEY=VALUE, one per line)</div>
                    <textarea style={{ ...inputStyle, height: 60, resize: 'vertical' }} value={editEnv} onChange={e => setEditEnv(e.target.value)} />
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button onClick={() => setEditing(null)} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>Cancel</button>
                    <button onClick={() => updateMutation.mutate(name)} style={{ padding: '3px 10px', borderRadius: 4, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: 'pointer' }}>Save</button>
                  </div>
                </div>
              ) : (
                /* View mode */
                <div>
                  <div style={{ fontSize: 11, marginBottom: 4 }}>
                    <span style={{ color: 'var(--text2)' }}>Command: </span>
                    <code style={{ fontFamily: "'SF Mono', monospace", color: 'var(--text)' }}>{config.command}</code>
                  </div>
                  {config.args?.length > 0 && (
                    <div style={{ fontSize: 11, marginBottom: 4 }}>
                      <span style={{ color: 'var(--text2)' }}>Args: </span>
                      <code style={{ fontFamily: "'SF Mono', monospace", color: 'var(--text)', fontSize: 10 }}>{config.args.join(' ')}</code>
                    </div>
                  )}
                  {config.env && Object.keys(config.env).length > 0 && (
                    <div style={{ fontSize: 11, marginBottom: 4 }}>
                      <span style={{ color: 'var(--text2)' }}>Env: </span>
                      {Object.entries(config.env).map(([k, v]) => (
                        <div key={k} style={{ paddingLeft: 12, fontSize: 10, fontFamily: "'SF Mono', monospace" }}>
                          <span style={{ color: 'var(--yellow)' }}>{k}</span>
                          <span style={{ color: 'var(--text2)' }}> = </span>
                          <span style={{ color: 'var(--text)' }}>{String(v).length > 40 ? String(v).slice(0, 40) + '...' : String(v)}</span>
                        </div>
                      ))}
                    </div>
                  )}
                  {config.url && (
                    <div style={{ fontSize: 11, marginBottom: 4 }}>
                      <span style={{ color: 'var(--text2)' }}>URL: </span>
                      <code style={{ fontFamily: "'SF Mono', monospace", color: 'var(--text)' }}>{config.url}</code>
                    </div>
                  )}
                  {testResults[name]?.error && (
                    <div style={{ fontSize: 10, color: 'var(--red)', background: 'rgba(255,107,107,0.1)', padding: '4px 8px', borderRadius: 4, marginTop: 4 }}>
                      {testResults[name].error}
                    </div>
                  )}
                  <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                    <button onClick={(e) => { e.stopPropagation(); testConnection(name); }} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--green)', fontSize: 10, cursor: 'pointer' }}>{testResults[name]?.loading ? 'Testing...' : 'Test Connection'}</button>
                    <button onClick={(e) => { e.stopPropagation(); startEdit(name, config); }} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 10, cursor: 'pointer' }}>Edit</button>
                    <button onClick={(e) => { e.stopPropagation(); if (confirm(`Delete MCP server "${name}"?`)) deleteMutation.mutate(name); }} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--red)', fontSize: 10, cursor: 'pointer' }}>Delete</button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function PermissionModeEditor({ agentType, currentMode, permissions }: { agentType: string; currentMode: string; permissions: any }) {
  const queryClient = useQueryClient();
  const modes = ['bypassPermissions', 'default', 'plan', 'acceptEdits'];

  const updateMode = useMutation({
    mutationFn: (mode: string) => fetch(`/api/settings/${agentType}/permissions`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ defaultMode: mode }),
    }).then(r => r.json()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['settings'] }),
  });

  const descriptions: Record<string, string> = {
    bypassPermissions: 'All tool calls are auto-approved without prompting.',
    default: 'Prompts for confirmation on each tool call.',
    plan: 'Requires plan approval before execution.',
    acceptEdits: 'Auto-approves file edits, prompts for other tools.',
  };

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 8 }}>
        {modes.map(mode => (
          <button key={mode} onClick={() => updateMode.mutate(mode)} style={{
            padding: '4px 10px', borderRadius: 6, fontSize: 10, cursor: 'pointer',
            border: mode === currentMode ? '1px solid var(--accent)' : '1px solid var(--border)',
            background: mode === currentMode ? 'rgba(108,92,231,0.15)' : 'var(--surface3)',
            color: mode === currentMode ? 'var(--accent2)' : 'var(--text2)',
          }}>{mode}</button>
        ))}
      </div>
      <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 8 }}>{descriptions[currentMode] ?? ''}</div>
      <JsonBlock data={permissions} />
    </div>
  );
}

function EnvVarEditor({ agentType, envVars }: { agentType: string; envVars: Record<string, string> }) {
  const queryClient = useQueryClient();
  const [showAdd, setShowAdd] = useState(false);
  const [newKey, setNewKey] = useState('');
  const [newValue, setNewValue] = useState('');
  const [editingKey, setEditingKey] = useState<string | null>(null);
  const [editValue, setEditValue] = useState('');

  const addMutation = useMutation({
    mutationFn: () => fetch(`/api/settings/${agentType}/config`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: `env.${newKey}`, value: newValue }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['settings'] }); setShowAdd(false); setNewKey(''); setNewValue(''); },
  });

  const updateMutation = useMutation({
    mutationFn: (key: string) => fetch(`/api/settings/${agentType}/config`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: `env.${key}`, value: editValue }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['settings'] }); setEditingKey(null); },
  });

  const deleteMutation = useMutation({
    mutationFn: (key: string) => fetch(`/api/settings/${agentType}/env/${key}`, { method: 'DELETE' }).then(r => r.json()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['settings'] }),
  });

  const inputStyle = { padding: '4px 8px', background: 'var(--bg)', border: '1px solid var(--border)', borderRadius: 4, color: 'var(--text)', fontSize: 11, fontFamily: "'SF Mono', monospace", outline: 'none' } as const;

  return (
    <div>
      {Object.entries(envVars).map(([k, v]) => (
        <div key={k} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '4px 0', borderBottom: '1px solid var(--border)' }}>
          <code style={{ fontFamily: "'SF Mono', monospace", color: 'var(--yellow)', fontSize: 11, minWidth: 160 }}>{k}</code>
          {editingKey === k ? (
            <>
              <input style={{ ...inputStyle, flex: 1 }} value={editValue} onChange={e => setEditValue(e.target.value)} />
              <button onClick={() => updateMutation.mutate(k)} style={{ padding: '2px 6px', borderRadius: 3, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 9, cursor: 'pointer' }}>Save</button>
              <button onClick={() => setEditingKey(null)} style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 9, cursor: 'pointer' }}>x</button>
            </>
          ) : (
            <>
              <code style={{ fontFamily: "'SF Mono', monospace", color: 'var(--text2)', fontSize: 11, flex: 1 }}>{String(v)}</code>
              <button onClick={() => { setEditingKey(k); setEditValue(String(v)); }} style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 9, cursor: 'pointer' }}>Edit</button>
              <button onClick={() => { if (confirm(`Delete ${k}?`)) deleteMutation.mutate(k); }} style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--red)', fontSize: 9, cursor: 'pointer' }}>x</button>
            </>
          )}
        </div>
      ))}

      {Object.keys(envVars).length === 0 && !showAdd && (
        <div style={{ fontSize: 11, color: 'var(--text2)', padding: 4 }}>No environment variables set.</div>
      )}

      {showAdd ? (
        <div style={{ display: 'flex', gap: 4, alignItems: 'center', padding: '6px 0' }}>
          <input style={{ ...inputStyle, width: 140 }} value={newKey} onChange={e => setNewKey(e.target.value)} placeholder="KEY" />
          <span style={{ color: 'var(--text2)', fontSize: 10 }}>=</span>
          <input style={{ ...inputStyle, flex: 1 }} value={newValue} onChange={e => setNewValue(e.target.value)} placeholder="value" />
          <button onClick={() => addMutation.mutate()} disabled={!newKey} style={{ padding: '2px 6px', borderRadius: 3, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 9, cursor: newKey ? 'pointer' : 'not-allowed', opacity: newKey ? 1 : 0.5 }}>Add</button>
          <button onClick={() => setShowAdd(false)} style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 9, cursor: 'pointer' }}>x</button>
        </div>
      ) : (
        <button onClick={() => setShowAdd(true)} style={{ marginTop: 6, padding: '3px 8px', borderRadius: 4, border: '1px dashed var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 10, cursor: 'pointer', width: '100%' }}>+ Add Variable</button>
      )}
    </div>
  );
}

function LanguageEditor({ agentType, currentLanguage }: { agentType: string; currentLanguage?: string }) {
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(currentLanguage ?? '');

  const updateMutation = useMutation({
    mutationFn: () => fetch(`/api/settings/${agentType}/config`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: 'language', value }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['settings'] }); setEditing(false); },
  });

  const languages = ['Korean', 'English', 'Japanese', 'Chinese', 'Spanish', 'French', 'German'];

  if (!editing) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 12, color: 'var(--text2)' }}>Agent responses will be in {currentLanguage ?? 'default language'}.</span>
        <button onClick={() => setEditing(true)} style={{ padding: '2px 8px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 10, cursor: 'pointer' }}>Change</button>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
      {languages.map(lang => (
        <button key={lang} onClick={() => { setValue(lang); }} style={{
          padding: '4px 10px', borderRadius: 6, fontSize: 10, cursor: 'pointer',
          border: lang === value ? '1px solid var(--accent)' : '1px solid var(--border)',
          background: lang === value ? 'rgba(108,92,231,0.15)' : 'var(--surface3)',
          color: lang === value ? 'var(--accent2)' : 'var(--text2)',
        }}>{lang}</button>
      ))}
      <div style={{ width: '100%', display: 'flex', gap: 4, marginTop: 6 }}>
        <button onClick={() => updateMutation.mutate()} style={{ padding: '3px 10px', borderRadius: 4, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: 'pointer' }}>Save</button>
        <button onClick={() => setEditing(false)} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>Cancel</button>
      </div>
    </div>
  );
}

function CodexSettingsSection({ agentType, settings }: { agentType: string; settings: any }) {
  const queryClient = useQueryClient();
  const [editingKey, setEditingKey] = useState(false);
  const [apiKey, setApiKey] = useState('');
  const [editingModel, setEditingModel] = useState(false);
  const [model, setModel] = useState(settings?.model ?? '');

  const models = ['o4-mini', 'o3', 'gpt-4o', 'gpt-4o-mini'];

  const saveApiKey = useMutation({
    mutationFn: () => fetch(`/api/settings/${agentType}/config`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: 'apiKey', value: apiKey }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['settings'] }); setEditingKey(false); setApiKey(''); },
  });

  const saveModel = useMutation({
    mutationFn: () => fetch(`/api/settings/${agentType}/config`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: 'model', value: model }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['settings'] }); setEditingModel(false); },
  });

  const inputStyle = { padding: '4px 8px', background: 'var(--bg)', border: '1px solid var(--border)', borderRadius: 4, color: 'var(--text)', fontSize: 11, fontFamily: "'SF Mono', monospace", outline: 'none' } as const;

  return (
    <>
      <Expandable label="API Key">
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 11, color: 'var(--text2)', flex: 1 }}>
            {settings?.apiKey ? '••••••••' + String(settings.apiKey).slice(-4) : 'Not set'}
          </span>
          {editingKey ? (
            <>
              <input style={{ ...inputStyle, flex: 1 }} type="password" value={apiKey} onChange={e => setApiKey(e.target.value)} placeholder="sk-..." />
              <button onClick={() => saveApiKey.mutate()} disabled={!apiKey} style={{ padding: '2px 8px', borderRadius: 3, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: 'pointer' }}>Save</button>
              <button onClick={() => setEditingKey(false)} style={{ padding: '2px 6px', borderRadius: 3, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>x</button>
            </>
          ) : (
            <button onClick={() => setEditingKey(true)} style={{ padding: '2px 8px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 10, cursor: 'pointer' }}>Set Key</button>
          )}
        </div>
      </Expandable>

      <Expandable label={`Model — ${settings?.model ?? 'not set'}`}>
        {editingModel ? (
          <div>
            <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginBottom: 8 }}>
              {models.map(m => (
                <button key={m} onClick={() => setModel(m)} style={{
                  padding: '4px 10px', borderRadius: 6, fontSize: 10, cursor: 'pointer',
                  border: m === model ? '1px solid var(--accent)' : '1px solid var(--border)',
                  background: m === model ? 'rgba(108,92,231,0.15)' : 'var(--surface3)',
                  color: m === model ? 'var(--accent2)' : 'var(--text2)',
                }}>{m}</button>
              ))}
            </div>
            <div style={{ display: 'flex', gap: 4 }}>
              <input style={{ ...inputStyle, flex: 1 }} value={model} onChange={e => setModel(e.target.value)} placeholder="custom model name" />
              <button onClick={() => saveModel.mutate()} style={{ padding: '3px 10px', borderRadius: 4, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: 'pointer' }}>Save</button>
              <button onClick={() => setEditingModel(false)} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>Cancel</button>
            </div>
          </div>
        ) : (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span style={{ fontSize: 12, color: 'var(--text2)', flex: 1 }}>{settings?.model ?? 'Default model will be used'}</span>
            <button onClick={() => { setModel(settings?.model ?? ''); setEditingModel(true); }} style={{ padding: '2px 8px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 10, cursor: 'pointer' }}>Change</button>
          </div>
        )}
      </Expandable>

      {settings?.provider !== undefined && (
        <Expandable label={`Provider — ${settings.provider ?? 'not set'}`}>
          <JsonBlock data={{ provider: settings.provider }} />
        </Expandable>
      )}
    </>
  );
}

function CursorSettingsSection({ agentType, settings, configPath }: { agentType: string; settings: any; configPath?: string }) {
  const queryClient = useQueryClient();
  const [editingRules, setEditingRules] = useState(false);
  const [rulesContent, setRulesContent] = useState('');

  const { data: rulesData } = useQuery({
    queryKey: ['cursor-rules', agentType],
    queryFn: async () => {
      try {
        const res = await fetch(`/api/settings/${agentType}/claudemd`);
        const json = await res.json();
        return json.ok ? json.data : null;
      } catch { return null; }
    },
  });

  const saveRules = useMutation({
    mutationFn: () => fetch(`/api/settings/${agentType}/claudemd`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: rulesContent }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['cursor-rules'] }); setEditingRules(false); },
  });

  return (
    <>
      {configPath && (
        <Expandable label="Config Path">
          <code style={{ fontSize: 12, color: 'var(--text2)', fontFamily: "'SF Mono', monospace" }}>{configPath}</code>
        </Expandable>
      )}

      <Expandable label="Rules File (.cursorrules)">
        {rulesData ? (
          editingRules ? (
            <div>
              <textarea
                value={rulesContent}
                onChange={e => setRulesContent(e.target.value)}
                style={{ width: '100%', height: 200, padding: 10, background: 'var(--bg)', border: '1px solid var(--border)', borderRadius: 6, color: 'var(--text)', fontSize: 11, fontFamily: "'SF Mono', monospace", outline: 'none', resize: 'vertical', lineHeight: 1.5 }}
              />
              <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                <button onClick={() => saveRules.mutate()} style={{ padding: '3px 10px', borderRadius: 4, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: 'pointer' }}>Save</button>
                <button onClick={() => setEditingRules(false)} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>Cancel</button>
              </div>
            </div>
          ) : (
            <div>
              <pre style={{ background: 'var(--surface3)', borderRadius: 6, padding: 10, fontSize: 11, fontFamily: "'SF Mono', monospace", color: 'var(--text)', overflow: 'auto', maxHeight: 200, margin: 0, lineHeight: 1.5, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                {rulesData.content || 'No rules defined.'}
              </pre>
              <div style={{ marginTop: 6 }}>
                <button onClick={() => { setRulesContent(rulesData.content ?? ''); setEditingRules(true); }} style={{ padding: '3px 10px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 10, cursor: 'pointer' }}>Edit</button>
              </div>
              {rulesData.path && <div style={{ fontSize: 10, color: 'var(--text2)', marginTop: 4, fontFamily: "'SF Mono', monospace" }}>{rulesData.path}</div>}
            </div>
          )
        ) : (
          <div style={{ fontSize: 11, color: 'var(--text2)', padding: 4 }}>Rules file not available for this agent type.</div>
        )}
      </Expandable>

      <Expandable label="Raw Settings (JSON)">
        <JsonBlock data={settings} />
      </Expandable>
    </>
  );
}

function ClaudeMdEditor({ agentType }: { agentType: string }) {
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [editContent, setEditContent] = useState('');

  const { data, isLoading } = useQuery({
    queryKey: ['claudemd', agentType],
    queryFn: async () => {
      const res = await fetch(`/api/settings/${agentType}/claudemd`);
      const json = await res.json();
      return json.data as { path: string; content: string };
    },
  });

  const saveMutation = useMutation({
    mutationFn: () => fetch(`/api/settings/${agentType}/claudemd`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: editContent }),
    }).then(r => r.json()),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['claudemd'] }); setEditing(false); },
  });

  if (isLoading) return <div style={{ fontSize: 11, color: 'var(--text2)' }}>Loading...</div>;

  const content = data?.content ?? '';

  if (editing) {
    return (
      <div>
        <textarea
          value={editContent}
          onChange={e => setEditContent(e.target.value)}
          style={{
            width: '100%', height: 300, padding: 12, background: 'var(--bg)', border: '1px solid var(--border)',
            borderRadius: 8, color: 'var(--text)', fontSize: 11, fontFamily: "'SF Mono', monospace",
            outline: 'none', resize: 'vertical', lineHeight: 1.6,
          }}
        />
        <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
          <button onClick={() => saveMutation.mutate()} style={{ padding: '4px 12px', borderRadius: 4, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 10, cursor: 'pointer' }}>Save</button>
          <button onClick={() => setEditing(false)} style={{ padding: '4px 12px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text2)', fontSize: 10, cursor: 'pointer' }}>Cancel</button>
        </div>
      </div>
    );
  }

  return (
    <div>
      {content ? (
        <pre style={{
          background: 'var(--surface3)', borderRadius: 8, padding: 12, fontSize: 11,
          fontFamily: "'SF Mono', monospace", color: 'var(--text)', overflow: 'auto',
          maxHeight: 300, margin: 0, lineHeight: 1.6, whiteSpace: 'pre-wrap', wordBreak: 'break-word',
        }}>{content}</pre>
      ) : (
        <div style={{ fontSize: 11, color: 'var(--text2)', padding: 8 }}>No CLAUDE.md found. Click Edit to create one.</div>
      )}
      <div style={{ marginTop: 8 }}>
        <button onClick={() => { setEditContent(content); setEditing(true); }} style={{ padding: '4px 12px', borderRadius: 4, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--accent2)', fontSize: 10, cursor: 'pointer' }}>Edit</button>
      </div>
      {data?.path && <div style={{ fontSize: 10, color: 'var(--text2)', marginTop: 4, fontFamily: "'SF Mono', monospace" }}>{data.path}</div>}
    </div>
  );
}

function PluginToggleList({ agentType, enabledPlugins, marketplaces }: { agentType: string; enabledPlugins: Record<string, boolean>; marketplaces: Record<string, any> }) {
  const queryClient = useQueryClient();
  const [expanded, setExpanded] = useState<string | null>(null);

  const toggleMutation = useMutation({
    mutationFn: ({ pluginId, enabled }: { pluginId: string; enabled: boolean }) =>
      fetch(`/api/settings/${agentType}/plugins/${encodeURIComponent(pluginId)}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled }),
      }).then(r => r.json()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['settings'] }),
  });

  const sorted = Object.entries(enabledPlugins).sort(([, a], [, b]) => (a === b ? 0 : a ? -1 : 1));

  return (
    <div>
      {sorted.map(([id, enabled]) => {
        const name = id.split('@')[0];
        const source = id.split('@')[1] ?? '';
        const marketplace = marketplaces[source];
        const repoUrl = marketplace?.source?.repo ?? marketplace?.source?.url ?? '';
        return (
          <div key={id} style={{ borderBottom: '1px solid var(--border)' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '5px 0' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', flex: 1 }} onClick={() => setExpanded(expanded === id ? null : id)}>
                <span style={{ fontSize: 10, color: 'var(--text2)', transform: expanded === id ? 'rotate(90deg)' : 'none', transition: 'transform 0.15s' }}>▶</span>
                <span style={{ fontSize: 12, color: enabled ? 'var(--text)' : 'var(--text2)' }}>{name}</span>
                <span style={{ fontSize: 10, color: 'var(--text2)' }}>{source}</span>
              </div>
              <button
                onClick={() => toggleMutation.mutate({ pluginId: id, enabled: !enabled })}
                style={{
                  padding: '2px 10px', borderRadius: 10, border: 'none', fontSize: 10, fontWeight: 600, cursor: 'pointer',
                  background: enabled ? 'var(--green)' : 'var(--surface3)',
                  color: enabled ? '#fff' : 'var(--text2)',
                }}
              >{enabled ? 'ON' : 'OFF'}</button>
            </div>
            {expanded === id && (
              <div style={{ padding: '4px 0 8px 20px', fontSize: 11 }}>
                <div style={{ color: 'var(--text2)' }}>
                  <span>Source: </span>
                  <span style={{ color: 'var(--text)', fontFamily: "'SF Mono', monospace" }}>{source}</span>
                </div>
                {repoUrl && (
                  <div style={{ color: 'var(--text2)', marginTop: 2 }}>
                    <span>Repo: </span>
                    <span style={{ color: 'var(--accent2)', fontFamily: "'SF Mono', monospace" }}>{repoUrl}</span>
                  </div>
                )}
                {!repoUrl && source === 'claude-plugins-official' && (
                  <div style={{ color: 'var(--text2)', marginTop: 2 }}>Anthropic official plugin</div>
                )}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function TagList({ items, color }: { items: string[]; color: string }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, padding: '4px 0' }}>
      {items.map(item => (
        <span key={item} style={{ padding: '3px 8px', background: `${color}18`, borderRadius: 4, fontSize: 10, color }}>{item}</span>
      ))}
    </div>
  );
}

function AgentCard({ agent }: { agent: AgentSettings }) {
  const meta = adapterMeta[agent.type] ?? { name: agent.type, color: '#888', icon: '?' };
  const s = agent.settings as any;

  const permMode = s?.permissions?.defaultMode;
  const language = s?.language;
  const allowList: string[] = s?.permissions?.allow ?? [];
  const tools = allowList.filter(p => !p.startsWith('mcp__'));
  const mcpPerms = allowList.filter(p => p.startsWith('mcp__')).map(p => p.replace('mcp__', '').replace(/__\*$/, ''));
  const plugins = s?.enabledPlugins ? Object.entries(s.enabledPlugins).filter(([, v]) => v).map(([k]) => k.split('@')[0]) : [];
  const disabledPlugins = s?.enabledPlugins ? Object.entries(s.enabledPlugins).filter(([, v]) => !v).map(([k]) => k.split('@')[0]) : [];
  const envVars = s?.env ? Object.entries(s.env) : [];
  const marketplaces = s?.extraKnownMarketplaces ? Object.keys(s.extraKnownMarketplaces) : [];

  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, overflow: 'hidden' }}>
      {/* Header */}
      <div style={{ padding: '16px 18px', borderBottom: '1px solid var(--border)', display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 44, height: 44, borderRadius: 10, background: `linear-gradient(135deg, ${meta.color}, ${meta.color}88)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 700, color: '#fff' }}>{meta.icon}</div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 16, fontWeight: 600 }}>{meta.name}</div>
          <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2 }}>{agent.version ?? 'Not detected'}</div>
        </div>
        <span style={{
          padding: '4px 12px', borderRadius: 6, fontSize: 11, fontWeight: 600,
          background: agent.installed ? 'rgba(0,206,201,0.1)' : 'rgba(136,136,160,0.1)',
          color: agent.installed ? 'var(--green)' : 'var(--text2)',
        }}>
          {agent.installed ? '● Connected' : '○ Not Found'}
        </span>
      </div>

      {agent.installed ? (
        <div style={{ padding: '4px 18px' }}>
          {agent.type === 'codex_local' ? (
            /* Codex-specific sections */
            <CodexSettingsSection agentType={agent.type} settings={s} />
          ) : agent.type === 'cursor_local' ? (
            /* Cursor-specific sections */
            <CursorSettingsSection agentType={agent.type} settings={s} configPath={agent.configPath} />
          ) : (
            /* Claude (and fallback) sections */
            <>
              {/* Config path */}
              <Expandable label="Config Path">
                <code style={{ fontSize: 12, color: 'var(--text2)', fontFamily: "'SF Mono', monospace" }}>{agent.configPath}</code>
              </Expandable>

              {/* Permission Mode */}
              {permMode && (
                <Expandable label={`Permission Mode — ${permMode}`}>
                  <PermissionModeEditor agentType={agent.type} currentMode={permMode} permissions={s.permissions} />
                </Expandable>
              )}

              {/* MCP Servers — detail + add/delete */}
              <Expandable label="MCP Servers" count={Object.keys(s.mcpServers ?? {}).length}>
                <McpDetailList agentType={agent.type} servers={s.mcpServers ?? {}} />
              </Expandable>

              {/* CLAUDE.md */}
              <Expandable label="CLAUDE.md">
                <ClaudeMdEditor agentType={agent.type} />
              </Expandable>

              {/* Plugins — with toggle + marketplace source */}
              {(plugins.length > 0 || disabledPlugins.length > 0) && (
                <Expandable label="Plugins" count={plugins.length + disabledPlugins.length}>
                  <PluginToggleList agentType={agent.type} enabledPlugins={s.enabledPlugins ?? {}} marketplaces={s.extraKnownMarketplaces ?? {}} />
                </Expandable>
              )}

              {/* Env vars */}
              <Expandable label="Environment Variables" count={envVars.length}>
                <EnvVarEditor agentType={agent.type} envVars={s.env ?? {}} />
              </Expandable>

              {/* Language */}
              <Expandable label={`Language — ${language ?? 'not set'}`}>
                <LanguageEditor agentType={agent.type} currentLanguage={language} />
              </Expandable>

              {/* Raw JSON */}
              <Expandable label="Raw Settings (JSON)">
                <JsonBlock data={agent.settings} />
              </Expandable>
            </>
          )}
        </div>
      ) : (
        <div style={{ padding: '24px 18px', textAlign: 'center' }}>
          <div style={{ color: 'var(--text2)', fontSize: 13, marginBottom: 12 }}>
            {meta.name} CLI is not installed or config file not found.
          </div>
          <div style={{ fontSize: 11, color: 'var(--text2)', lineHeight: 1.6 }}>
            {agent.type === 'codex_local' && (
              <span>Install Codex CLI: <code style={{ color: 'var(--accent2)', fontFamily: "'SF Mono', monospace" }}>npm install -g @openai/codex</code></span>
            )}
            {agent.type === 'cursor_local' && (
              <span>Install Cursor from <code style={{ color: 'var(--accent2)', fontFamily: "'SF Mono', monospace" }}>cursor.com</code> and enable CLI access</span>
            )}
            {agent.type === 'claude_local' && (
              <span>Install Claude Code: <code style={{ color: 'var(--accent2)', fontFamily: "'SF Mono', monospace" }}>npm install -g @anthropic-ai/claude-code</code></span>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

export function Settings() {
  const { data: agents, isLoading } = useQuery({ queryKey: ['settings'], queryFn: fetchSettings });

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Agent Settings</h1>
        <p style={{ fontSize: 13, color: 'var(--text2)', marginTop: 4 }}>Global configuration for detected AI agents</p>
      </div>

      {isLoading ? (
        <div style={{ color: 'var(--text2)', padding: 20 }}>Detecting agents...</div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(440px, 1fr))', gap: 16 }}>
          {(agents ?? []).map(agent => (
            <AgentCard key={agent.type} agent={agent} />
          ))}
        </div>
      )}
    </div>
  );
}
