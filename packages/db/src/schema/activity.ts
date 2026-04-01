import { pgTable, uuid, varchar, text, timestamp, jsonb, real, integer } from 'drizzle-orm/pg-core';
import { projects } from './projects.js';
import { agents } from './agents.js';

export const activityLog = pgTable('activity_log', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').references(() => projects.id, { onDelete: 'set null' }),
  agentId: uuid('agent_id').references(() => agents.id, { onDelete: 'set null' }),
  eventType: varchar('event_type', { length: 100 }).notNull(),
  detail: jsonb('detail').default({}).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

export const costDaily = pgTable('cost_daily', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  agentId: uuid('agent_id').notNull().references(() => agents.id, { onDelete: 'cascade' }),
  date: varchar('date', { length: 10 }).notNull(),
  totalUsd: real('total_usd').notNull().default(0),
  tokensIn: integer('tokens_in').notNull().default(0),
  tokensOut: integer('tokens_out').notNull().default(0),
});
