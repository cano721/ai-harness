import { useState } from 'react';
import { Routes, Route } from 'react-router-dom';
import { Sidebar } from './components/Sidebar.js';
import { Dashboard } from './pages/Dashboard.js';
import { Settings } from './pages/Settings.js';
import { Projects } from './pages/Projects.js';
import { ProjectDetail } from './pages/ProjectDetail.js';
import { Agents } from './pages/Agents.js';
import { AgentDetail } from './pages/AgentDetail.js';
import { Tasks } from './pages/Tasks.js';
import { Conventions } from './pages/Conventions.js';
import { Security } from './pages/Security.js';
import { Activity } from './pages/Activity.js';
import { Costs } from './pages/Costs.js';
import { OrgChart } from './pages/OrgChart.js';
import { Metrics } from './pages/Metrics.js';

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
      </main>
    </div>
  );
}
