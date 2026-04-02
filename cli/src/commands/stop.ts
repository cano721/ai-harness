import { existsSync, readFileSync, unlinkSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { DEFAULT_PORT, DEFAULT_HOST, API_PREFIX } from '@ddalkak/shared';

export async function stopCommand(_args: string[]) {
  const pidFile = join(homedir(), '.ddalkak', 'server.pid');

  if (existsSync(pidFile)) {
    const pid = parseInt(readFileSync(pidFile, 'utf-8').trim(), 10);
    try {
      process.kill(pid, 'SIGTERM');
      unlinkSync(pidFile);
      console.log(`  Server (PID ${pid}) stopped.`);
    } catch (err: any) {
      if (err.code === 'ESRCH') {
        // Process already gone
        unlinkSync(pidFile);
        console.log(`  Server process (PID ${pid}) was not running. PID file removed.`);
      } else {
        console.error(`  Failed to stop server: ${err.message}`);
        process.exit(1);
      }
    }
    return;
  }

  // No PID file - check via health API
  const url = `http://${DEFAULT_HOST}:${DEFAULT_PORT}${API_PREFIX}/health`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
    if (res.ok) {
      console.log(`  Server is running at ${url} but no PID file found.`);
      console.log(`  Stop it manually or use: kill $(lsof -ti tcp:${DEFAULT_PORT})`);
    }
  } catch {
    console.log('  Server is not running.');
  }
}
