import { PGlite } from '@electric-sql/pglite';
import { drizzle } from 'drizzle-orm/pglite';
import * as schema from './schema/index.js';
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
  pgliteInstance = new PGlite(dir);
  dbInstance = drizzle(pgliteInstance, { schema });

  await runMigrations(dbInstance);

  return dbInstance;
}

async function runMigrations(db: ReturnType<typeof drizzle<typeof schema>>) {
  const tables = [
    `CREATE TABLE IF NOT EXISTS projects (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      name VARCHAR(255) NOT NULL,
      path TEXT,
      git_url TEXT,
      description TEXT,
      created_at TIMESTAMP DEFAULT NOW() NOT NULL,
      updated_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS project_relations (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      source_project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      target_project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      type VARCHAR(50) NOT NULL DEFAULT 'depends_on',
      created_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS agents (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      name VARCHAR(255) NOT NULL,
      adapter_type VARCHAR(50) NOT NULL,
      config JSONB NOT NULL DEFAULT '{}',
      status VARCHAR(50) NOT NULL DEFAULT 'idle',
      last_heartbeat TIMESTAMP,
      created_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS conventions (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      scope VARCHAR(50) NOT NULL DEFAULT 'project',
      category VARCHAR(100) NOT NULL,
      rule TEXT NOT NULL,
      enabled BOOLEAN NOT NULL DEFAULT true,
      created_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS guardrails (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      key VARCHAR(100) NOT NULL,
      value TEXT NOT NULL,
      source VARCHAR(20) NOT NULL DEFAULT 'db',
      created_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS tasks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      agent_id UUID REFERENCES agents(id) ON DELETE SET NULL,
      title VARCHAR(500) NOT NULL,
      description TEXT,
      status VARCHAR(50) NOT NULL DEFAULT 'todo',
      created_at TIMESTAMP DEFAULT NOW() NOT NULL,
      updated_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS task_runs (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
      run_id VARCHAR(100) NOT NULL,
      started_at TIMESTAMP DEFAULT NOW() NOT NULL,
      ended_at TIMESTAMP,
      exit_code INTEGER,
      cost_usd REAL,
      tokens_in INTEGER,
      tokens_out INTEGER
    )`,
    `CREATE TABLE IF NOT EXISTS activity_log (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID REFERENCES projects(id) ON DELETE SET NULL,
      agent_id UUID REFERENCES agents(id) ON DELETE SET NULL,
      event_type VARCHAR(100) NOT NULL,
      detail JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMP DEFAULT NOW() NOT NULL
    )`,
    `CREATE TABLE IF NOT EXISTS cost_daily (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
      date VARCHAR(10) NOT NULL,
      total_usd REAL NOT NULL DEFAULT 0,
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0
    )`,
  ];

  for (const sql of tables) {
    await db.execute(sql);
  }
}

export async function closeDb() {
  if (pgliteInstance) {
    await pgliteInstance.close();
    pgliteInstance = null;
    dbInstance = null;
  }
}

export type Database = NonNullable<typeof dbInstance>;
