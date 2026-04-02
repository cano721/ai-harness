import { NavLink } from 'react-router-dom';

const navItems = [
  { label: 'Dashboard', path: '/', icon: '📊' },
  { label: 'Agents', path: '/agents', icon: '🤖' },
  { label: 'Tasks', path: '/tasks', icon: '📋' },
  { section: 'Governance' },
  { label: 'Conventions', path: '/conventions', icon: '📐' },
  { label: 'Security', path: '/security', icon: '🛡' },
  { label: 'Audit Log', path: '/activity', icon: '📝' },
  { section: 'Workspace' },
  { label: 'Projects', path: '/projects', icon: '📦' },
  { label: 'Org Chart', path: '/orgchart', icon: '🗂' },
  { label: 'Costs', path: '/costs', icon: '💰' },
  { label: 'Metrics', path: '/metrics', icon: '📈' },
  { label: 'Settings', path: '/settings', icon: '⚙' },
];

export function Sidebar() {
  return (
    <aside
      style={{
        width: 240,
        background: 'var(--surface)',
        borderRight: '1px solid var(--border)',
        display: 'flex',
        flexDirection: 'column',
        flexShrink: 0,
      }}
    >
      <div
        style={{
          padding: 20,
          borderBottom: '1px solid var(--border)',
          display: 'flex',
          alignItems: 'center',
          gap: 10,
        }}
      >
        <div
          style={{
            width: 32,
            height: 32,
            background: 'linear-gradient(135deg, var(--accent), var(--green))',
            borderRadius: 8,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 16,
          }}
        >
          ⚡
        </div>
        <span style={{ fontSize: 18, fontWeight: 700, letterSpacing: -0.5 }}>
          Ddalkak
        </span>
        <span
          style={{
            fontSize: 10,
            color: 'var(--text2)',
            background: 'var(--surface3)',
            padding: '2px 6px',
            borderRadius: 4,
            marginLeft: 'auto',
          }}
        >
          alpha
        </span>
      </div>

      <nav style={{ flex: 1, padding: '8px 0' }}>
        {navItems.map((item, i) => {
          if ('section' in item) {
            return (
              <div
                key={i}
                style={{
                  padding: '16px 16px 8px',
                  fontSize: 10,
                  textTransform: 'uppercase',
                  letterSpacing: 1.5,
                  color: 'var(--text2)',
                }}
              >
                {item.section}
              </div>
            );
          }
          return (
            <NavLink
              key={item.path}
              to={item.path}
              style={({ isActive }) => ({
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                padding: '9px 16px',
                margin: '1px 8px',
                borderRadius: 8,
                fontSize: 13,
                color: isActive ? 'var(--accent2)' : 'var(--text2)',
                background: isActive ? 'rgba(108,92,231,0.15)' : 'transparent',
                textDecoration: 'none',
              })}
            >
              <span style={{ width: 18, textAlign: 'center', fontSize: 14 }}>
                {item.icon}
              </span>
              {item.label}
            </NavLink>
          );
        })}
      </nav>
    </aside>
  );
}
