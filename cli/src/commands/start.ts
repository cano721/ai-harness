import { startServer } from '@ddalkak/server';
import { DEFAULT_PORT, DEFAULT_HOST } from '@ddalkak/shared';
import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

export async function startCommand(args: string[]) {
  let port = DEFAULT_PORT;
  let host = DEFAULT_HOST;
  let open = true;

  for (let i = 0; i < args.length; i++) {
    if ((args[i] === '--port' || args[i] === '-p') && args[i + 1]) {
      port = parseInt(args[++i], 10);
    }
    if ((args[i] === '--host') && args[i + 1]) {
      host = args[++i];
    }
    if (args[i] === '--no-open') {
      open = false;
    }
  }

  // Write PID file
  const ddalkakDir = join(homedir(), '.ddalkak');
  mkdirSync(ddalkakDir, { recursive: true });
  writeFileSync(join(ddalkakDir, 'server.pid'), String(process.pid), 'utf-8');

  await startServer({ port, host, open });
}
