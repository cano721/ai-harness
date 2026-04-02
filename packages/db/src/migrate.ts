import { migrate } from 'drizzle-orm/pglite/migrator';
import { drizzle } from 'drizzle-orm/pglite';
import * as schema from './schema/index.js';
import { fileURLToPath } from 'url';
import { dirname, join, resolve } from 'path';
import { existsSync } from 'fs';

function getMigrationsFolder(): string {
  // Try import.meta.url first (works in production)
  try {
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = dirname(__filename);
    const candidate = join(__dirname, 'migrations');
    if (existsSync(join(candidate, 'meta', '_journal.json'))) {
      return candidate;
    }
  } catch {}

  // Fallback for vitest environment: resolve from known package location
  const candidates = [
    resolve(process.cwd(), 'packages/db/src/migrations'),
    resolve(process.cwd(), 'src/migrations'),
    new URL('./migrations', import.meta.url).pathname,
  ];
  for (const candidate of candidates) {
    if (existsSync(join(candidate, 'meta', '_journal.json'))) {
      return candidate;
    }
  }

  // Final fallback using import.meta.url as-is
  const __filename = fileURLToPath(import.meta.url);
  return join(dirname(__filename), 'migrations');
}

export async function runMigrations(db: ReturnType<typeof drizzle<typeof schema>>) {
  const migrationsFolder = getMigrationsFolder();
  await migrate(db, { migrationsFolder });
}
