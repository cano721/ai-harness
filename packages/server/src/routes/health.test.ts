import { describe, it, expect } from 'vitest';
import { createApp } from '../app.js';
import type { Express } from 'express';

async function startTestServer(app: Express): Promise<{ port: number; close: () => void }> {
  return new Promise((resolve) => {
    const server = app.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      resolve({ port, close: () => server.close() });
    });
  });
}

describe('Health API', () => {
  it('GET /api/health returns ok', async () => {
    const app = createApp();
    const { port, close } = await startTestServer(app);

    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/health`);
      const json = await res.json();
      expect(res.status).toBe(200);
      expect(json.ok).toBe(true);
      expect(json.version).toBeDefined();
    } finally {
      close();
    }
  });
});
