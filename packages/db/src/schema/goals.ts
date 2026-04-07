import { pgTable, uuid, varchar, text, timestamp, integer, uniqueIndex } from 'drizzle-orm/pg-core';
import type { AnyPgColumn } from 'drizzle-orm/pg-core';
import { projects } from './projects.js';
import { agents } from './agents.js';

export const goals = pgTable('goals', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  parentGoalId: uuid('parent_goal_id').references((): AnyPgColumn => goals.id, { onDelete: 'cascade' }),
  title: varchar('title', { length: 255 }).notNull(),
  description: text('description'),
  status: varchar('status', { length: 50 }).notNull().default('planned'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
});

export const projectAutomationRoutines = pgTable('project_automation_routines', {
  id: uuid('id').primaryKey().defaultRandom(),
  projectId: uuid('project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  name: varchar('name', { length: 255 }).notNull(),
  description: text('description'),
  status: varchar('status', { length: 50 }).notNull().default('paused'),
  heartbeatMinutes: integer('heartbeat_minutes').notNull().default(2),
  developerAgentId: uuid('developer_agent_id').references(() => agents.id, { onDelete: 'set null' }),
  reviewerAgentId: uuid('reviewer_agent_id').references(() => agents.id, { onDelete: 'set null' }),
  verifierAgentId: uuid('verifier_agent_id').references(() => agents.id, { onDelete: 'set null' }),
  lastEvaluatedAt: timestamp('last_evaluated_at'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
}, (table) => [
  uniqueIndex('project_automation_routines_project_idx').on(table.projectId),
]);
