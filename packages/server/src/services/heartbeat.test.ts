import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createApp } from '../app.js';
import { createDb, closeDb, agents, projects, activityLog } from '@ddalkak/db';
import { eq } from 'drizzle-orm';
import type { Express } from 'express';
import { HeartbeatService } from './heartbeat.service.js';

let close: () => void;
let base: string;

async function startTestServer(app: Express): Promise<{ port: number; close: () => void }> {
  return new Promise((resolve) => {
    const server = app.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      const p = typeof addr === 'object' && addr ? addr.port : 0;
      resolve({ port: p, close: () => server.close() });
    });
  });
}

async function post(path: string, body: unknown) {
  return fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

beforeAll(async () => {
  await createDb(':memory:');
  const app = createApp();
  const server = await startTestServer(app);
  close = server.close;
  base = `http://127.0.0.1:${server.port}/api`;
});

afterAll(async () => {
  close();
  await closeDb();
});

describe('Heartbeat API', () => {
  let projectId: string;
  let agentId: string;

  it('setup: create project and agent', async () => {
    const res = await post('/projects', { name: 'hb-test' });
    projectId = ((await res.json()) as any).data.id;
    const res2 = await post('/agents', { projectId, name: 'hb-agent', adapterType: 'claude_local' });
    agentId = ((await res2.json()) as any).data.id;
  });

  it('POST /agents/:id/heartbeat updates lastHeartbeat', async () => {
    const res = await post(`/agents/${agentId}/heartbeat`, {});
    const json = await res.json() as any;
    expect(res.status).toBe(200);
    expect(json.ok).toBe(true);
    expect(json.data.lastHeartbeat).toBeDefined();
  });

  it('POST /agents/:id/heartbeat returns 404 for unknown agent', async () => {
    const res = await post('/agents/00000000-0000-0000-0000-000000000000/heartbeat', {});
    expect(res.status).toBe(404);
  });
});

describe('HeartbeatService.checkTimeouts', () => {
  it('marks timed-out running agents as error and logs activity', async () => {
    const db = await createDb(':memory:');

    // Create project and agent
    const [project] = await db.insert(projects).values({ name: 'timeout-test' }).returning();
    const [agent] = await db.insert(agents).values({
      projectId: project.id,
      name: 'timeout-agent',
      adapterType: 'claude_local',
      status: 'running',
      lastHeartbeat: new Date(Date.now() - 60_000), // 60s ago = timed out
    }).returning();

    const service = new HeartbeatService();
    await service.checkTimeouts();

    const [updated] = await db.select().from(agents).where(eq(agents.id, agent.id));
    expect(updated.status).toBe('error');

    const logs = await db.select().from(activityLog).where(eq(activityLog.agentId, agent.id));
    expect(logs.length).toBe(1);
    expect(logs[0].eventType).toBe('agent.timeout');
  });

  it('does not affect idle or paused agents', async () => {
    const db = await createDb(':memory:');

    const [project] = await db.insert(projects).values({ name: 'no-timeout-test' }).returning();
    const [idleAgent] = await db.insert(agents).values({
      projectId: project.id,
      name: 'idle-agent',
      adapterType: 'claude_local',
      status: 'idle',
      lastHeartbeat: new Date(Date.now() - 60_000),
    }).returning();

    const service = new HeartbeatService();
    await service.checkTimeouts();

    const [updated] = await db.select().from(agents).where(eq(agents.id, idleAgent.id));
    expect(updated.status).toBe('idle');
  });

  it('does not affect running agents with recent heartbeat', async () => {
    const db = await createDb(':memory:');

    const [project] = await db.insert(projects).values({ name: 'recent-hb-test' }).returning();
    const [agent] = await db.insert(agents).values({
      projectId: project.id,
      name: 'recent-agent',
      adapterType: 'claude_local',
      status: 'running',
      lastHeartbeat: new Date(), // just now
    }).returning();

    const service = new HeartbeatService();
    await service.checkTimeouts();

    const [updated] = await db.select().from(agents).where(eq(agents.id, agent.id));
    expect(updated.status).toBe('running');
  });
});
