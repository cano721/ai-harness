import { pgTable, uuid, varchar, text, timestamp } from 'drizzle-orm/pg-core';

export const projects = pgTable('projects', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: varchar('name', { length: 255 }).notNull(),
  path: text('path'),
  gitUrl: text('git_url'),
  description: text('description'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
});

export const projectRelations = pgTable('project_relations', {
  id: uuid('id').primaryKey().defaultRandom(),
  sourceProjectId: uuid('source_project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  targetProjectId: uuid('target_project_id').notNull().references(() => projects.id, { onDelete: 'cascade' }),
  type: varchar('type', { length: 50 }).notNull().default('depends_on'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
