import { Suspense, lazy, useState } from 'react';
import { Routes, Route } from 'react-router-dom';
import { Sidebar } from './components/Sidebar.js';

const Dashboard = lazy(async () => {
  const module = await import('./pages/Dashboard.js');
  return { default: module.Dashboard };
});
const Settings = lazy(async () => {
  const module = await import('./pages/Settings.js');
  return { default: module.Settings };
});
const Projects = lazy(async () => {
  const module = await import('./pages/Projects.js');
  return { default: module.Projects };
});
const ProjectDetail = lazy(async () => {
  const module = await import('./pages/ProjectDetail.js');
  return { default: module.ProjectDetail };
});
const Agents = lazy(async () => {
  const module = await import('./pages/Agents.js');
  return { default: module.Agents };
});
const AgentDetail = lazy(async () => {
  const module = await import('./pages/AgentDetail.js');
  return { default: module.AgentDetail };
});
const Tasks = lazy(async () => {
  const module = await import('./pages/Tasks.js');
  return { default: module.Tasks };
});
const Conventions = lazy(async () => {
  const module = await import('./pages/Conventions.js');
  return { default: module.Conventions };
});
const Security = lazy(async () => {
  const module = await import('./pages/Security.js');
  return { default: module.Security };
});
const Activity = lazy(async () => {
  const module = await import('./pages/Activity.js');
  return { default: module.Activity };
});
const Costs = lazy(async () => {
  const module = await import('./pages/Costs.js');
  return { default: module.Costs };
});
const OrgChart = lazy(async () => {
  const module = await import('./pages/OrgChart.js');
  return { default: module.OrgChart };
});
const Metrics = lazy(async () => {
  const module = await import('./pages/Metrics.js');
  return { default: module.Metrics };
});

export default function App() {
  const [sidebarOpen, setSidebarOpen] = useState(false);

  return (
    <div className="app-shell">
      <Sidebar open={sidebarOpen} onNavigate={() => setSidebarOpen(false)} />
      {sidebarOpen && <button className="sidebar-backdrop" onClick={() => setSidebarOpen(false)} aria-label="Close navigation" />}
      <main className="app-main">
        <div className="topbar">
          <button className="topbar-menu" onClick={() => setSidebarOpen((open) => !open)} aria-label="Toggle navigation">
            Menu
          </button>
          <div className="topbar-copy">
            <span className="topbar-eyebrow">Ddalkak Platform</span>
            <strong>Agent control plane for Guard, Guide, Gear</strong>
          </div>
        </div>
        <Suspense fallback={<div style={{ color: 'var(--text2)', padding: 24 }}>Loading page...</div>}>
          <Routes>
            <Route path="/" element={<Dashboard />} />
            <Route path="/settings" element={<Settings />} />
            <Route path="/projects" element={<Projects />} />
            <Route path="/projects/:id" element={<ProjectDetail />} />
            <Route path="/agents" element={<Agents />} />
            <Route path="/agents/:id" element={<AgentDetail />} />
            <Route path="/tasks" element={<Tasks />} />
            <Route path="/conventions" element={<Conventions />} />
            <Route path="/security" element={<Security />} />
            <Route path="/activity" element={<Activity />} />
            <Route path="/costs" element={<Costs />} />
            <Route path="/orgchart" element={<OrgChart />} />
            <Route path="/metrics" element={<Metrics />} />
          </Routes>
        </Suspense>
      </main>
    </div>
  );
}
