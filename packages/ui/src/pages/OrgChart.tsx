import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';

interface Project {
  id: string;
  name: string;
  path?: string;
  description?: string;
}

interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: string;
  status: string;
}

interface Relation {
  id: string;
  sourceProjectId: string;
  targetProjectId: string;
  type: string;
}

const agentStatusColor: Record<string, string> = {
  running: 'var(--green)',
  idle: 'var(--text2)',
  error: 'var(--red)',
  paused: 'var(--yellow)',
  terminated: 'var(--text2)',
};

function AgentNode({ agent }: { agent: Agent }) {
  const navigate = useNavigate();
  const color = agentStatusColor[agent.status] ?? 'var(--text2)';
  return (
    <div
      onClick={(e) => { e.stopPropagation(); navigate(`/agents`); }}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 6,
        padding: '5px 10px',
        background: 'var(--surface3)',
        border: '1px solid var(--border)',
        borderRadius: 8,
        cursor: 'pointer',
        fontSize: 12,
        userSelect: 'none',
      }}
    >
      <svg width="8" height="8" viewBox="0 0 8 8">
        <circle cx="4" cy="4" r="4" fill={color} />
      </svg>
      <span style={{ fontWeight: 500 }}>{agent.name}</span>
      <span style={{ fontSize: 10, color: 'var(--text2)' }}>{agent.adapterType.replace('_local', '')}</span>
    </div>
  );
}

function ProjectNode({
  project,
  agents,
  relations,
  allProjects,
}: {
  project: Project;
  agents: Agent[];
  relations: Relation[];
  allProjects: Project[];
}) {
  const navigate = useNavigate();
  const outgoing = relations.filter(r => r.sourceProjectId === project.id);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 12 }}>
      {/* Project card */}
      <div
        onClick={() => navigate(`/projects/${project.id}`)}
        style={{
          padding: '12px 16px',
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 12,
          cursor: 'pointer',
          minWidth: 220,
          userSelect: 'none',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: agents.length > 0 ? 10 : 0 }}>
          <span style={{ fontSize: 16 }}>📦</span>
          <span style={{ fontSize: 14, fontWeight: 600 }}>{project.name}</span>
        </div>
        {agents.length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {agents.map(a => <AgentNode key={a.id} agent={a} />)}
          </div>
        )}
        {agents.length === 0 && (
          <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 4 }}>No agents</div>
        )}
      </div>

      {/* Outgoing relations */}
      {outgoing.length > 0 && (
        <div style={{ paddingLeft: 20, display: 'flex', flexDirection: 'column', gap: 8 }}>
          {outgoing.map(rel => {
            const target = allProjects.find(p => p.id === rel.targetProjectId);
            if (!target) return null;
            return (
              <div key={rel.id} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                {/* Connector line */}
                <svg width="20" height="20" viewBox="0 0 20 20" style={{ flexShrink: 0 }}>
                  <path d="M0 0 L0 10 L20 10" stroke="var(--border)" strokeWidth="1.5" fill="none" />
                  <polygon points="18,7 20,10 18,13" fill="var(--border)" />
                </svg>
                <span style={{ fontSize: 10, color: 'var(--text2)', background: 'var(--surface3)', padding: '2px 6px', borderRadius: 4 }}>
                  {rel.type}
                </span>
                <div
                  onClick={() => navigate(`/projects/${target.id}`)}
                  style={{
                    padding: '6px 12px',
                    background: 'var(--surface)',
                    border: '1px solid var(--border)',
                    borderRadius: 8,
                    cursor: 'pointer',
                    fontSize: 13,
                    fontWeight: 500,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 6,
                  }}
                >
                  <span>📦</span> {target.name}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

export function OrgChart() {
  const { data: projects, isLoading: loadingProjects } = useQuery({
    queryKey: ['projects'],
    queryFn: () => api.get<Project[]>('/projects'),
  });
  const { data: agents, isLoading: loadingAgents } = useQuery({
    queryKey: ['agents'],
    queryFn: () => api.get<Agent[]>('/agents'),
  });
  const { data: relations, isLoading: loadingRelations } = useQuery({
    queryKey: ['relations'],
    queryFn: () => api.get<Relation[]>('/relations'),
  });

  const isLoading = loadingProjects || loadingAgents || loadingRelations;

  const projectList = projects ?? [];
  const agentList = agents ?? [];
  const relationList = relations ?? [];

  // Projects that are targets of relations — render them inline, not as top-level
  const targetProjectIds = new Set(relationList.map(r => r.targetProjectId));
  const rootProjects = projectList.filter(p => !targetProjectIds.has(p.id));

  const legend = [
    { label: 'Running', color: 'var(--green)' },
    { label: 'Idle', color: 'var(--text2)' },
    { label: 'Error', color: 'var(--red)' },
    { label: 'Paused', color: 'var(--yellow)' },
  ];

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Org Chart</h1>
        <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
          {legend.map(l => (
            <div key={l.label} style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: 'var(--text2)' }}>
              <svg width="8" height="8" viewBox="0 0 8 8">
                <circle cx="4" cy="4" r="4" fill={l.color} />
              </svg>
              {l.label}
            </div>
          ))}
        </div>
      </div>

      {isLoading ? (
        <div style={{ color: 'var(--text2)' }}>Loading...</div>
      ) : projectList.length === 0 ? (
        <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
          <div style={{ fontSize: 32, marginBottom: 8 }}>🗂</div>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>No projects yet</div>
          <div style={{ fontSize: 13 }}>Create a project to see the org chart.</div>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
          {(rootProjects.length > 0 ? rootProjects : projectList).map(project => (
            <ProjectNode
              key={project.id}
              project={project}
              agents={agentList.filter(a => a.projectId === project.id)}
              relations={relationList}
              allProjects={projectList}
            />
          ))}
        </div>
      )}
    </div>
  );
}
