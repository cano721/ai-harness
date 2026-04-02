import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createApp } from '../app.js';
import { createDb, closeDb } from '@ddalkak/db';
import type { Express } from 'express';

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

async function patch(path: string, body: unknown) {
  return fetch(`${base}${path}`, {
    method: 'PATCH',
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

describe('Validation middleware', () => {
  it('POST /projects - 400 when name is missing', async () => {
    const res = await post('/projects', { path: '/tmp/test' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });

  it('POST /projects - 201 when name is provided', async () => {
    const res = await post('/projects', { name: 'valid-project' });
    expect(res.status).toBe(201);
    const json = await res.json() as any;
    expect(json.ok).toBe(true);
  });

  it('POST /agents - 400 when projectId is missing', async () => {
    const res = await post('/agents', { name: 'worker', adapterType: 'claude_local' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });

  it('POST /agents - 400 when name is missing', async () => {
    const res = await post('/agents', { projectId: 'some-id', adapterType: 'claude_local' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });

  it('POST /tasks - 400 when title is missing', async () => {
    const res = await post('/tasks', { projectId: 'some-id' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });

  it('POST /relations - 400 when sourceProjectId is missing', async () => {
    const res = await post('/relations', { targetProjectId: 'target-id' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });

  it('POST /relations - 400 when targetProjectId is missing', async () => {
    const res = await post('/relations', { sourceProjectId: 'source-id' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });

  it('POST /guardrails/:projectId - 400 when key is missing', async () => {
    const res = await post('/guardrails/some-project-id', { value: '10' });
    const json = await res.json() as any;
    expect(res.status).toBe(400);
    expect(json.ok).toBe(false);
    expect(json.error).toMatch(/Validation error/);
  });
});
