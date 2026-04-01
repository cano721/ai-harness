import { pgTable, uuid, varchar, text, timestamp, jsonb } from 'drizzle-orm/pg-core';
import { projects } from './projects.js';

export const agents = pgTable('agents', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  name: varchar('name', { length: 255 }).notNull(),
  adapterType: varchar('adapter_type', { length: 50 }).notNull(),
  config: jsonb('config').default({}).notNull(),
  status: varchar('status', { length: 50 }).notNull().default('idle'),
  lastHeartbeat: timestamp('last_heartbeat'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
