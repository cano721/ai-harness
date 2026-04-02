import { NavLink } from 'react-router-dom';

const navItems = [
  { label: 'Dashboard', path: '/', short: 'DB' },
  { label: 'Agents', path: '/agents', short: 'AG' },
  { label: 'Tasks', path: '/tasks', short: 'TS' },
  { section: 'Governance' },
  { label: 'Conventions', path: '/conventions', short: 'CV' },
  { label: 'Security', path: '/security', short: 'SC' },
  { label: 'Audit Log', path: '/activity', short: 'AL' },
  { section: 'Workspace' },
  { label: 'Projects', path: '/projects', short: 'PJ' },
  { label: 'Org Chart', path: '/orgchart', short: 'OR' },
  { label: 'Costs', path: '/costs', short: 'CS' },
  { label: 'Metrics', path: '/metrics', short: 'MT' },
  { label: 'Settings', path: '/settings', short: 'ST' },
];

export function Sidebar({ open, onNavigate }: { open: boolean; onNavigate: () => void }) {
  return (
    <aside className={`sidebar ${open ? 'is-open' : ''}`}>
      <div className="sidebar-brand">
        <div className="sidebar-brand-mark">DD</div>
        <div>
          <div className="sidebar-brand-title">Ddalkak</div>
          <div className="sidebar-brand-subtitle">Guard + Guide + Gear</div>
        </div>
        <span className="sidebar-badge">alpha</span>
      </div>

      <nav className="sidebar-nav">
        {navItems.map((item, i) => {
          if ('section' in item) {
            return (
              <div key={i} className="sidebar-section">{item.section}</div>
            );
          }
          return (
            <NavLink
              key={item.path}
              to={item.path}
              onClick={onNavigate}
              className={({ isActive }) => `sidebar-link ${isActive ? 'is-active' : ''}`}
            >
              <span className="sidebar-link-mark">{item.short}</span>
              {item.label}
            </NavLink>
          );
        })}
      </nav>

      <div className="sidebar-status">
        <div className="sidebar-status-label">Control Plane</div>
        <strong>Ready for local agent orchestration</strong>
        <p>Projects, adapters, hooks, and conventions are surfaced from one workspace.</p>
      </div>
    </aside>
  );
}
