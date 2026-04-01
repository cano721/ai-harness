import { Routes, Route } from 'react-router-dom';
import { Sidebar } from './components/Sidebar.js';
import { Dashboard } from './pages/Dashboard.js';
import { Settings } from './pages/Settings.js';
import { Projects } from './pages/Projects.js';
import { Agents } from './pages/Agents.js';
import { Tasks } from './pages/Tasks.js';
import { Conventions } from './pages/Conventions.js';
import { Security } from './pages/Security.js';
import { Activity } from './pages/Activity.js';
import { Costs } from './pages/Costs.js';

export default function App() {
  return (
    <div style={{ display: 'flex', height: '100vh', overflow: 'hidden' }}>
      <Sidebar />
      <main style={{ flex: 1, overflow: 'auto' }}>
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/settings" element={<Settings />} />
          <Route path="/projects" element={<Projects />} />
          <Route path="/agents" element={<Agents />} />
          <Route path="/tasks" element={<Tasks />} />
          <Route path="/conventions" element={<Conventions />} />
          <Route path="/security" element={<Security />} />
          <Route path="/activity" element={<Activity />} />
          <Route path="/costs" element={<Costs />} />
        </Routes>
      </main>
    </div>
  );
}
