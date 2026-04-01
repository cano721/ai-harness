import { createApp } from './app.js';
import { createDb, closeDb } from '@ddalkak/db';
import { DEFAULT_PORT, DEFAULT_HOST, APP_NAME } from '@ddalkak/shared';

export { createApp };

export async function startServer(options?: { port?: number; host?: string; open?: boolean }) {
  const port = options?.port ?? DEFAULT_PORT;
  const host = options?.host ?? DEFAULT_HOST;

  // Initialize database
  await createDb();

  const app = createApp();

  return new Promise<void>((resolve) => {
    const server = app.listen(port, host, () => {
      const url = `http://${host}:${port}`;
      console.log(`\n  ⚡ ${APP_NAME} is running at ${url}\n`);

      if (options?.open) {
        import('child_process').then(({ exec }) => {
          const cmd = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open';
          exec(`${cmd} ${url}`);
        });
      }

      resolve();
    });

    const shutdown = async () => {
      console.log('\n  Shutting down...');
      server.close();
      await closeDb();
      process.exit(0);
    };

    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
  });
}
