import { startServer } from '@ddalkak/server';
import { DEFAULT_PORT, DEFAULT_HOST } from '@ddalkak/shared';

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

  await startServer({ port, host, open });
}
