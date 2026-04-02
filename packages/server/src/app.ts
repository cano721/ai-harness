import express from 'express';
import cors from 'cors';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { existsSync } from 'fs';
import { API_PREFIX, APP_VERSION } from '@ddalkak/shared';
import { heartbeatService } from './services/heartbeat.service.js';
import { projectsRouter } from './routes/projects.js';
import { agentsRouter } from './routes/agents.js';
import { settingsRouter } from './routes/settings.js';
import { dashboardRouter } from './routes/dashboard.js';
import { conventionsRouter } from './routes/conventions.js';
import { guardrailsRouter } from './routes/guardrails.js';
import { relationsRouter } from './routes/relations.js';
import { tasksRouter } from './routes/tasks.js';
import { costsRouter } from './routes/costs.js';
import { activityRouter } from './routes/activity.js';
import { skillsRouter } from './routes/skills.js';
import { metricsRouter } from './routes/metrics.js';

export function createApp() {
  const app = express();

  app.use(cors({ origin: true, credentials: true }));
  app.use(express.json());

  // Start heartbeat monitoring
  heartbeatService.start();

  // API routes
  app.use(`${API_PREFIX}/projects`, projectsRouter);
  app.use(`${API_PREFIX}/agents`, agentsRouter);
  app.use(`${API_PREFIX}/settings`, settingsRouter);
  app.use(`${API_PREFIX}/dashboard`, dashboardRouter);
  app.use(`${API_PREFIX}/conventions`, conventionsRouter);
  app.use(`${API_PREFIX}/guardrails`, guardrailsRouter);
  app.use(`${API_PREFIX}/relations`, relationsRouter);
  app.use(`${API_PREFIX}/tasks`, tasksRouter);
  app.use(`${API_PREFIX}/costs`, costsRouter);
  app.use(`${API_PREFIX}/activity`, activityRouter);
  app.use(`${API_PREFIX}/skills`, skillsRouter);
  app.use(`${API_PREFIX}/metrics`, metricsRouter);

  // Health check
  app.get(`${API_PREFIX}/health`, (_req, res) => {
    res.json({ ok: true, version: APP_VERSION });
  });

  // Serve UI static files (production)
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const uiDistPath = join(__dirname, '../../ui/dist');
  if (existsSync(uiDistPath)) {
    app.use(express.static(uiDistPath));
    app.get('/{*splat}', (_req, res) => {
      res.sendFile(join(uiDistPath, 'index.html'));
    });
  }

  // JSON error handler (must be last middleware)
  app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    console.error('Unhandled error:', err);
    res.status(500).json({ ok: false, error: err.message });
  });

  // Stop heartbeat on process exit
  process.once('SIGINT', () => heartbeatService.stop());
  process.once('SIGTERM', () => heartbeatService.stop());

  return app;
}
