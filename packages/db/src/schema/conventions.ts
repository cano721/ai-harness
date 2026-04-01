import { pgTable, uuid, varchar, text, boolean, timestamp } from 'drizzle-orm/pg-core';
import { projects } from './projects.js';

export const conventions = pgTable('conventions', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  scope: varchar('scope', { length: 50 }).notNull().default('project'),
  category: varchar('category', { length: 100 }).notNull(),
  rule: text('rule').notNull(),
  enabled: boolean('enabled').notNull().default(true),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

export const guardrails = pgTable('guardrails', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  key: varchar('key', { length: 100 }).notNull(),
  value: text('value').notNull(),
  source: varchar('source', { length: 20 }).notNull().default('db'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
