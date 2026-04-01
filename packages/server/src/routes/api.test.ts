import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createApp } from '../app.js';
import { createDb, closeDb } from '@ddalkak/db';
import type { Express } from 'express';

let port: number;
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

async function get(path: string) {
  return fetch(`${base}${path}`);
}

async function patch(path: string, body: unknown) {
  return fetch(`${base}${path}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function del(path: string) {
  return fetch(`${base}${path}`, { method: 'DELETE' });
}

beforeAll(async () => {
  await createDb(':memory:');
  const app = createApp();
  const server = await startTestServer(app);
  port = server.port;
  close = server.close;
  base = `http://127.0.0.1:${port}/api`;
});

afterAll(async () => {
  close();
  await closeDb();
});

describe('Projects API', () => {
  let projectId: string;

  it('POST /projects creates a project', async () => {
    const res = await post('/projects', { name: 'test-proj', path: '/tmp/test' });
    const json = await res.json() as any;
    expect(res.status).toBe(201);
    expect(json.ok).toBe(true);
    expect(json.data.name).toBe('test-proj');
    projectId = json.data.id;
  });

  it('GET /projects lists projects', async () => {
    const res = await get('/projects');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.length).toBeGreaterThan(0);
  });

  it('GET /projects/:id returns single project', async () => {
    const res = await get(`/projects/${projectId}`);
    const json = await res.json() as any;
    expect(json.data.name).toBe('test-proj');
  });

  it('PATCH /projects/:id updates project', async () => {
    const res = await patch(`/projects/${projectId}`, { name: 'updated-proj' });
    const json = await res.json() as any;
    expect(json.data.name).toBe('updated-proj');
  });

  it('GET /projects/:id 404 for missing', async () => {
    const res = await get('/projects/00000000-0000-0000-0000-000000000000');
    expect(res.status).toBe(404);
  });

  it('DELETE /projects/:id deletes project', async () => {
    const res = await del(`/projects/${projectId}`);
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
  });
});

describe('Agents API', () => {
  let projectId: string;
  let agentId: string;

  it('setup: create project', async () => {
    const res = await post('/projects', { name: 'agent-test' });
    projectId = ((await res.json()) as any).data.id;
  });

  it('POST /agents creates agent', async () => {
    const res = await post('/agents', { projectId, name: 'worker-1', adapterType: 'claude_local' });
    const json = await res.json() as any;
    expect(res.status).toBe(201);
    expect(json.data.name).toBe('worker-1');
    expect(json.data.status).toBe('idle');
    agentId = json.data.id;
  });

  it('GET /agents lists agents', async () => {
    const res = await get('/agents');
    const json = await res.json() as any;
    expect(json.data.length).toBeGreaterThan(0);
  });

  it('PATCH /agents/:id updates agent', async () => {
    const res = await patch(`/agents/${agentId}`, { status: 'running' });
    const json = await res.json() as any;
    expect(json.data.status).toBe('running');
  });

  it('DELETE /agents/:id deletes agent', async () => {
    const res = await del(`/agents/${agentId}`);
    expect((await res.json() as any).ok).toBe(true);
  });
});

describe('Conventions API', () => {
  let projectId: string;
  let convId: string;

  it('setup: create project', async () => {
    const res = await post('/projects', { name: 'conv-test' });
    projectId = ((await res.json()) as any).data.id;
  });

  it('POST /conventions/:projectId creates convention', async () => {
    const res = await post(`/conventions/${projectId}`, { category: 'style', rule: 'no-var', scope: 'project' });
    const json = await res.json() as any;
    expect(res.status).toBe(201);
    expect(json.data.rule).toBe('no-var');
    convId = json.data.id;
  });

  it('GET /conventions/:projectId lists conventions', async () => {
    const res = await get(`/conventions/${projectId}`);
    const json = await res.json() as any;
    expect(json.data.length).toBe(1);
  });

  it('PATCH /conventions/:projectId/:id updates', async () => {
    const res = await patch(`/conventions/${projectId}/${convId}`, { enabled: false });
    const json = await res.json() as any;
    expect(json.data.enabled).toBe(false);
  });

  it('DELETE /conventions/:projectId/:id deletes', async () => {
    const res = await del(`/conventions/${projectId}/${convId}`);
    expect((await res.json() as any).ok).toBe(true);
  });
});

describe('Guardrails API', () => {
  let projectId: string;

  it('setup: create project', async () => {
    const res = await post('/projects', { name: 'guard-test' });
    projectId = ((await res.json()) as any).data.id;
  });

  it('POST /guardrails/:projectId creates guardrail', async () => {
    const res = await post(`/guardrails/${projectId}`, { key: 'max_files', value: '10' });
    const json = await res.json() as any;
    expect(res.status).toBe(201);
    expect(json.data.key).toBe('max_files');
  });

  it('POST /guardrails/:projectId upserts on same key', async () => {
    await post(`/guardrails/${projectId}`, { key: 'max_files', value: '20' });
    const res = await get(`/guardrails/${projectId}`);
    const json = await res.json() as any;
    const maxFiles = json.data.filter((g: any) => g.key === 'max_files');
    expect(maxFiles.length).toBe(1);
    expect(maxFiles[0].value).toBe('20');
  });
});

describe('Tasks API', () => {
  let projectId: string;
  let agentId: string;
  let taskId: string;

  it('setup: create project and agent', async () => {
    let res = await post('/projects', { name: 'task-test' });
    projectId = ((await res.json()) as any).data.id;
    res = await post('/agents', { projectId, name: 'runner', adapterType: 'claude_local' });
    agentId = ((await res.json()) as any).data.id;
  });

  it('POST /tasks creates task', async () => {
    const res = await post('/tasks', { projectId, title: 'Do something', agentId });
    const json = await res.json() as any;
    expect(res.status).toBe(201);
    expect(json.data.title).toBe('Do something');
    expect(json.data.status).toBe('todo');
    taskId = json.data.id;
  });

  it('GET /tasks lists tasks', async () => {
    const res = await get(`/tasks?projectId=${projectId}`);
    const json = await res.json() as any;
    expect(json.data.length).toBe(1);
  });

  it('POST /tasks/:id/checkout assigns agent', async () => {
    const res = await post(`/tasks/${taskId}/checkout`, { agentId });
    const json = await res.json() as any;
    expect(json.data.status).toBe('in_progress');
  });

  it('POST /tasks/:id/checkout returns 409 on double checkout', async () => {
    const res = await post(`/tasks/${taskId}/checkout`, { agentId });
    expect(res.status).toBe(409);
  });

  it('PATCH /tasks/:id updates task', async () => {
    const res = await patch(`/tasks/${taskId}`, { status: 'done' });
    const json = await res.json() as any;
    expect(json.data.status).toBe('done');
  });

  it('GET /tasks/:id/runs returns run history', async () => {
    const res = await get(`/tasks/${taskId}/runs`);
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(Array.isArray(json.data)).toBe(true);
  });
});

describe('Relations API', () => {
  let projectAId: string;
  let projectBId: string;
  let relationId: string;

  it('setup: create two projects', async () => {
    let res = await post('/projects', { name: 'proj-a' });
    projectAId = ((await res.json()) as any).data.id;
    res = await post('/projects', { name: 'proj-b' });
    projectBId = ((await res.json()) as any).data.id;
  });

  it('POST /relations creates relation', async () => {
    const res = await post('/relations', { sourceProjectId: projectAId, targetProjectId: projectBId, type: 'depends_on' });
    const json = await res.json() as any;
    expect(res.status).toBe(201);
    expect(json.data.type).toBe('depends_on');
    relationId = json.data.id;
  });

  it('GET /relations/:projectId returns relations', async () => {
    const res = await get(`/relations/${projectAId}`);
    const json = await res.json() as any;
    expect(json.data.length).toBe(1);
    expect(json.data[0].sourceProject.name).toBe('proj-a');
    expect(json.data[0].targetProject.name).toBe('proj-b');
  });

  it('DELETE /relations/:id deletes relation', async () => {
    const res = await del(`/relations/${relationId}`);
    expect((await res.json() as any).ok).toBe(true);
  });
});

describe('Costs API', () => {
  it('GET /costs/summary returns totals', async () => {
    const res = await get('/costs/summary');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data).toHaveProperty('totalUsd');
  });

  it('GET /costs/by-agent returns breakdown', async () => {
    const res = await get('/costs/by-agent');
    expect((await res.json() as any).ok).toBe(true);
  });

  it('GET /costs/by-project returns breakdown', async () => {
    const res = await get('/costs/by-project');
    expect((await res.json() as any).ok).toBe(true);
  });

  it('GET /costs/daily returns chart data', async () => {
    const res = await get('/costs/daily?days=7');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(Array.isArray(json.data)).toBe(true);
  });
});

describe('Activity API', () => {
  it('GET /activity returns events', async () => {
    const res = await get('/activity?limit=10');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(Array.isArray(json.data)).toBe(true);
  });

  it('GET /activity/counts returns today counts', async () => {
    const res = await get('/activity/counts');
    const json = await res.json() as any;
    expect(json.data).toHaveProperty('securityEventsToday');
    expect(json.data).toHaveProperty('taskEventsToday');
  });

  it('GET /activity/security returns security events', async () => {
    const res = await get('/activity/security');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
  });
});

describe('Dashboard API', () => {
  it('GET /dashboard returns real aggregated data', async () => {
    const res = await get('/dashboard');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.activeAgents).toBeGreaterThanOrEqual(0);
    expect(json.data).toHaveProperty('conventionCompliance');
    expect(json.data).toHaveProperty('securityEvents');
    expect(json.data).toHaveProperty('monthlyCostUsd');
  });
});

describe('Settings API', () => {
  it('GET /settings returns 3 agent types', async () => {
    const res = await get('/settings');
    const json = await res.json() as any;
    expect(json.data).toHaveLength(3);
    const types = json.data.map((s: any) => s.type);
    expect(types).toContain('claude_local');
    expect(types).toContain('codex_local');
    expect(types).toContain('cursor_local');
  });

  it('GET /settings/claude_local returns claude settings', async () => {
    const res = await get('/settings/claude_local');
    const json = await res.json() as any;
    expect(json.data.type).toBe('claude_local');
  });

  it('GET /settings/unknown returns 404', async () => {
    const res = await get('/settings/unknown_agent');
    expect(res.status).toBe(404);
  });

  it('GET /settings/claude_local/hooks returns hooks', async () => {
    const res = await get('/settings/claude_local/hooks');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
  });

  it('GET /settings/claude_local/plugins returns plugins', async () => {
    const res = await get('/settings/claude_local/plugins');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data).toHaveProperty('plugins');
    expect(json.data).toHaveProperty('marketplaces');
  });

  it('POST /settings/claude_local/mcp adds MCP server', async () => {
    const res = await post('/settings/claude_local/mcp', {
      name: 'vitest-mcp',
      command: 'npx',
      args: ['-y', '@test/mcp'],
      env: { KEY: 'val' },
    });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.command).toBe('npx');
  });

  it('GET /settings/claude_local/mcp/vitest-mcp returns detail', async () => {
    const res = await get('/settings/claude_local/mcp/vitest-mcp');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.name).toBe('vitest-mcp');
    expect(json.data.command).toBe('npx');
    expect(json.data.env.KEY).toBe('val');
  });

  it('POST /settings/claude_local/mcp updates existing (delete + re-create)', async () => {
    // Update by re-creating with same name but different args
    await del('/settings/claude_local/mcp/vitest-mcp');
    const res = await post('/settings/claude_local/mcp', {
      name: 'vitest-mcp',
      command: 'node',
      args: ['--inspect', 'server.js'],
      env: { NEW_KEY: 'new-val' },
    });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.command).toBe('node');

    // Verify updated values
    const detail = await get('/settings/claude_local/mcp/vitest-mcp');
    const detailJson = await detail.json() as any;
    expect(detailJson.data.command).toBe('node');
    expect(detailJson.data.args).toEqual(['--inspect', 'server.js']);
    expect(detailJson.data.env.NEW_KEY).toBe('new-val');
  });

  it('DELETE /settings/claude_local/mcp/vitest-mcp removes it', async () => {
    const res = await del('/settings/claude_local/mcp/vitest-mcp');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);

    // Verify it's gone
    const check = await get('/settings/claude_local/mcp/vitest-mcp');
    expect(check.status).toBe(404);
  });

  it('GET /settings/claude_local/mcp/nonexistent returns 404', async () => {
    const res = await get('/settings/claude_local/mcp/nonexistent');
    expect(res.status).toBe(404);
  });

  it('POST /settings/claude_local/mcp requires name and command', async () => {
    const res = await post('/settings/claude_local/mcp', { name: 'test' });
    expect(res.status).toBe(400);
  });

  it('POST /settings/claude_local/mcp/:name/test returns reachable for valid command', async () => {
    // Add a test MCP with a valid command (echo exits immediately)
    await post('/settings/claude_local/mcp', { name: 'test-echo', command: 'echo', args: ['hello'] });
    const res = await post('/settings/claude_local/mcp/test-echo/test', {});
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.status).toBe('reachable');
    // Cleanup
    await del('/settings/claude_local/mcp/test-echo');
  });

  it('POST /settings/claude_local/mcp/:name/test returns unreachable for invalid command', async () => {
    await post('/settings/claude_local/mcp', { name: 'test-bad', command: 'nonexistent-cmd-xyz', args: [] });
    const res = await post('/settings/claude_local/mcp/test-bad/test', {});
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.status).toBe('unreachable');
    expect(json.data.error).toBeDefined();
    // Cleanup
    await del('/settings/claude_local/mcp/test-bad');
  });

  it('POST /settings/claude_local/mcp/:name/test returns 404 for missing server', async () => {
    const res = await post('/settings/claude_local/mcp/nonexistent/test', {});
    expect(res.status).toBe(404);
  });

  it('POST /settings/claude_local/mcp/test-all tests all MCP servers', async () => {
    // Add two servers
    await post('/settings/claude_local/mcp', { name: 'all-test-ok', command: 'echo', args: ['hi'] });
    await post('/settings/claude_local/mcp', { name: 'all-test-bad', command: 'nonexistent-xyz', args: [] });

    const res = await post('/settings/claude_local/mcp-test-all', {});
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data['all-test-ok'].status).toBe('reachable');
    expect(json.data['all-test-bad'].status).toBe('unreachable');

    // Cleanup
    await del('/settings/claude_local/mcp/all-test-ok');
    await del('/settings/claude_local/mcp/all-test-bad');
  });

  it('PATCH /settings/claude_local/config updates a setting', async () => {
    const res = await patch('/settings/claude_local/config', { key: 'language', value: 'Korean' });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
  });

  it('PATCH /settings/claude_local/plugins/:id toggles plugin', async () => {
    const res = await patch('/settings/claude_local/plugins/test-plugin@test', { enabled: true });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.enabled).toBe(true);

    // Clean up
    await patch('/settings/claude_local/plugins/test-plugin@test', { enabled: false });
  });

  it('PATCH /settings/claude_local/permissions updates permissions', async () => {
    const res = await patch('/settings/claude_local/permissions', { defaultMode: 'bypassPermissions' });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.defaultMode).toBe('bypassPermissions');
  });

  it('PATCH /settings/claude_local/config sets env variable', async () => {
    const res = await patch('/settings/claude_local/config', { key: 'env.TEST_VAR', value: 'hello' });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.env.TEST_VAR).toBe('hello');
  });

  it('PATCH /settings/claude_local/config sets language', async () => {
    const res = await patch('/settings/claude_local/config', { key: 'language', value: 'English' });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(json.data.language).toBe('English');
    // Restore
    await patch('/settings/claude_local/config', { key: 'language', value: 'Korean' });
  });

  it('GET /settings/claude_local/claudemd returns CLAUDE.md content', async () => {
    const res = await get('/settings/claude_local/claudemd');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
    expect(typeof json.data.content).toBe('string');
    expect(typeof json.data.path).toBe('string');
  });

  it('PUT /settings/claude_local/claudemd updates CLAUDE.md', async () => {
    // Read current
    const before = await get('/settings/claude_local/claudemd');
    const original = (await before.json() as any).data.content;

    // Update
    const testContent = original + '\n# Test Section\n';
    const res = await fetch(`${base}/settings/claude_local/claudemd`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: testContent }),
    });
    const json = await res.json() as any;
    expect(json.ok).toBe(true);

    // Verify
    const after = await get('/settings/claude_local/claudemd');
    const updated = (await after.json() as any).data.content;
    expect(updated).toContain('# Test Section');

    // Restore
    await fetch(`${base}/settings/claude_local/claudemd`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: original }),
    });
  });

  it('DELETE /settings/claude_local/env/:key removes env variable', async () => {
    // Set first
    await patch('/settings/claude_local/config', { key: 'env.DELETE_ME', value: 'temp' });
    const res = await del('/settings/claude_local/env/DELETE_ME');
    const json = await res.json() as any;
    expect(json.ok).toBe(true);

    // Verify deleted
    const check = await get('/settings/claude_local');
    const settings = (await check.json() as any).data.settings;
    expect(settings.env?.DELETE_ME).toBeUndefined();
  });
});
