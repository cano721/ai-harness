import { PGlite } from '@electric-sql/pglite';
import { drizzle } from 'drizzle-orm/pglite';
import * as schema from './schema/index.js';
import { runMigrations } from './migrate.js';
import { homedir } from 'os';
import { join } from 'path';
import { mkdirSync } from 'fs';

export * from './schema/index.js';
export { schema };

let dbInstance: ReturnType<typeof drizzle<typeof schema>> | null = null;
let pgliteInstance: PGlite | null = null;

export function getDataDir(): string {
  const dir = join(homedir(), '.ddalkak', 'data');
  mkdirSync(dir, { recursive: true });
  return dir;
}

export async function createDb(dataDir?: string) {
  if (dbInstance) return dbInstance;

  const dir = dataDir ?? getDataDir();
  // ':memory:' is treated as in-memory (no args to PGlite = ephemeral)
  pgliteInstance = dir === ':memory:' ? new PGlite() : new PGlite(dir);
  dbInstance = drizzle(pgliteInstance, { schema });

  await runMigrations(dbInstance);

  return dbInstance;
}

export async function closeDb() {
  if (pgliteInstance) {
    await pgliteInstance.close();
    pgliteInstance = null;
    dbInstance = null;
  }
}

export type Database = NonNullable<typeof dbInstance>;
