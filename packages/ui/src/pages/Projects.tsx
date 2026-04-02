import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';

interface ProjectAnalysis {
  techStack: string[];
  git: { isRepo: boolean; url?: string; branch?: string };
  claudeMd: { exists: boolean; content?: string };
  agents: { name: string; path: string }[];
  hooks: { event: string; commands: string[] }[];
  skills: { name: string; path: string }[];
  conventions: { category: string; rule: string }[];
  installedCLIs: { claude: boolean; codex: boolean; cursor: boolean };
}

interface Project {
  id: string;
  name: string;
  path?: string;
  gitUrl?: string;
  description?: string;
  createdAt: string;
}

async function fetchProjects(): Promise<Project[]> {
  const res = await fetch('/api/projects');
  const json = await res.json();
  return json.data;
}

function CreateProjectModal({ onClose }: { onClose: () => void }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState('');
  const [path, setPath] = useState('');
  const [gitUrl, setGitUrl] = useState('');
  const [nameManuallyEdited, setNameManuallyEdited] = useState(false);
  const [analyzing, setAnalyzing] = useState(false);
  const [analyzeResult, setAnalyzeResult] = useState<ProjectAnalysis | null>(null);
  const [analyzeError, setAnalyzeError] = useState<string | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!path.trim()) {
      setAnalyzeResult(null);
      setAnalyzeError(null);
      return;
    }

    if (debounceRef.current) clearTimeout(debounceRef.current);

    debounceRef.current = setTimeout(async () => {
      setAnalyzing(true);
      setAnalyzeError(null);
      setAnalyzeResult(null);
      try {
        const res = await fetch('/api/projects/analyze', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path }),
        });
        const json = await res.json();
        if (!res.ok || !json.ok) {
          setAnalyzeError(json.error ?? '경로를 확인해주세요');
        } else {
          const data: ProjectAnalysis = json.data;
          setAnalyzeResult(data);
          if (!nameManuallyEdited) {
            const parts = path.replace(/\/$/, '').split('/');
            setName(parts[parts.length - 1] ?? '');
          }
        }
      } catch {
        setAnalyzeError('경로를 확인해주세요');
      } finally {
        setAnalyzing(false);
      }
    }, 500);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [path]);

  const mutation = useMutation({
    mutationFn: async () => {
      const res = await fetch('/api/projects', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, path: path || undefined, gitUrl: gitUrl || undefined }),
      });
      return res.json();
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['projects'] });
      onClose();
    },
  });

  const inputStyle = {
    width: '100%',
    padding: '8px 12px',
    background: 'var(--surface3)',
    border: '1px solid var(--border)',
    borderRadius: 8,
    color: 'var(--text)',
    fontSize: 13,
    outline: 'none',
    boxSizing: 'border-box' as const,
  } as const;

  const badgeStyle = (installed?: boolean) => ({
    padding: '2px 8px',
    borderRadius: 6,
    fontSize: 11,
    fontWeight: 600,
    background: installed === undefined
      ? 'rgba(116,185,255,0.15)'
      : installed
        ? 'rgba(0,206,201,0.1)'
        : 'var(--surface3)',
    color: installed === undefined
      ? 'var(--blue)'
      : installed
        ? 'var(--green)'
        : 'var(--text2)',
    display: 'inline-block',
  } as const);

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.6)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 100,
      }}
      onClick={onClose}
    >
      <div
        style={{
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 16,
          padding: 24,
          width: 480,
          maxHeight: '80vh',
          overflowY: 'auto',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <h2 style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>New Project</h2>

        <div style={{ marginBottom: 14 }}>
          <label style={{ fontSize: 12, color: 'var(--text2)', display: 'block', marginBottom: 4 }}>
            Local Path *
          </label>
          <input
            style={inputStyle}
            value={path}
            onChange={(e) => setPath(e.target.value)}
            placeholder="/Users/.../project"
            autoFocus
          />
          {analyzing && (
            <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 4 }}>분석 중...</div>
          )}
          {analyzeError && (
            <div style={{ fontSize: 11, color: 'var(--red)', marginTop: 4 }}>{analyzeError}</div>
          )}
        </div>

        {analyzeResult && (
          <div
            style={{
              marginBottom: 14,
              padding: 12,
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              borderRadius: 10,
              display: 'flex',
              flexDirection: 'column',
              gap: 10,
            }}
          >
            {analyzeResult.techStack.length > 0 && (
              <div>
                <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>감지된 스택</div>
                <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                  {analyzeResult.techStack.map((t) => (
                    <span key={t} style={badgeStyle()}>{t}</span>
                  ))}
                </div>
              </div>
            )}

            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>Git</span>
              {analyzeResult.git.isRepo ? (
                <span style={badgeStyle(true)}>✓ {analyzeResult.git.branch ?? 'repo'}</span>
              ) : (
                <span style={badgeStyle(false)}>not a repo</span>
              )}
            </div>

            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>CLAUDE.md</span>
              {analyzeResult.claudeMd.exists ? (
                <span style={badgeStyle(true)}>✓ 있음</span>
              ) : (
                <span style={badgeStyle(false)}>없음</span>
              )}
            </div>

            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>CLI</span>
              {(['claude', 'codex', 'cursor'] as const).map((key) => {
                const labels: Record<string, string> = { claude: 'Claude', codex: 'Codex', cursor: 'Cursor' };
                const installed = analyzeResult.installedCLIs[key];
                return (
                  <span key={key} style={badgeStyle(installed)}>
                    {labels[key]} {installed ? '✓' : '✗'}
                  </span>
                );
              })}
            </div>
          </div>
        )}

        <div style={{ marginBottom: 14 }}>
          <label style={{ fontSize: 12, color: 'var(--text2)', display: 'block', marginBottom: 4 }}>Name *</label>
          <input
            style={inputStyle}
            value={name}
            onChange={(e) => { setName(e.target.value); setNameManuallyEdited(true); }}
            placeholder="my-project"
          />
        </div>

        <div style={{ marginBottom: 20 }}>
          <label style={{ fontSize: 12, color: 'var(--text2)', display: 'block', marginBottom: 4 }}>
            Git URL (optional)
          </label>
          <input
            style={inputStyle}
            value={gitUrl}
            onChange={(e) => setGitUrl(e.target.value)}
            placeholder="https://github.com/..."
          />
        </div>

        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button
            onClick={onClose}
            style={{
              padding: '7px 14px',
              borderRadius: 8,
              border: '1px solid var(--border)',
              background: 'var(--surface2)',
              color: 'var(--text)',
              fontSize: 12,
              cursor: 'pointer',
            }}
          >
            Cancel
          </button>
          <button
            onClick={() => mutation.mutate()}
            disabled={!name || !path}
            style={{
              padding: '7px 14px',
              borderRadius: 8,
              border: '1px solid var(--accent)',
              background: 'var(--accent)',
              color: '#fff',
              fontSize: 12,
              cursor: name && path ? 'pointer' : 'not-allowed',
              opacity: name && path ? 1 : 0.5,
            }}
          >
            Create Project
          </button>
        </div>
      </div>
    </div>
  );
}

export function Projects() {
  const { data: projects, isLoading } = useQuery({ queryKey: ['projects'], queryFn: fetchProjects });
  const [showCreate, setShowCreate] = useState(false);
  const navigate = useNavigate();

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Projects</h1>
        <button
          onClick={() => setShowCreate(true)}
          style={{
            padding: '7px 14px',
            borderRadius: 8,
            border: '1px solid var(--accent)',
            background: 'var(--accent)',
            color: '#fff',
            fontSize: 12,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: 6,
          }}
        >
          + Add Project
        </button>
      </div>

      {isLoading ? (
        <div style={{ color: 'var(--text2)' }}>Loading...</div>
      ) : (projects ?? []).length === 0 ? (
        <div
          style={{
            padding: 40,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 12,
            textAlign: 'center',
            color: 'var(--text2)',
          }}
        >
          <div style={{ fontSize: 32, marginBottom: 8 }}>📦</div>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>No projects yet</div>
          <div style={{ fontSize: 13 }}>Create a project to start managing conventions and agents.</div>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {(projects ?? []).map((project) => (
            <div
              key={project.id}
              onClick={() => navigate(`/projects/${project.id}`)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 14,
                padding: '14px 18px',
                background: 'var(--surface)',
                border: '1px solid var(--border)',
                borderRadius: 12,
                cursor: 'pointer',
              }}
            >
              <div
                style={{
                  width: 40,
                  height: 40,
                  background: 'var(--surface3)',
                  borderRadius: 10,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 18,
                }}
              >
                📦
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, fontWeight: 600 }}>{project.name}</div>
                <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2, display: 'flex', gap: 12 }}>
                  {project.path && <span>{project.path}</span>}
                  {project.gitUrl && <span>{project.gitUrl}</span>}
                  {!project.path && !project.gitUrl && <span>No path linked</span>}
                </div>
              </div>
              <span style={{ fontSize: 11, color: 'var(--text2)' }}>
                {new Date(project.createdAt).toLocaleDateString()}
              </span>
            </div>
          ))}
        </div>
      )}

      {showCreate && <CreateProjectModal onClose={() => setShowCreate(false)} />}
    </div>
  );
}
