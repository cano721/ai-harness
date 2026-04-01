import { describe, it, expect, afterAll } from 'vitest';
import { createDb, closeDb, projects, agents, conventions, guardrails, tasks, activityLog, costDaily } from './index.js';
import { eq } from 'drizzle-orm';

describe('PGlite Database', () => {
  afterAll(async () => {
    await closeDb();
  });

  it('creates db and runs migrations', async () => {
    const db = await createDb(':memory:');
    expect(db).toBeDefined();
  });

  it('inserts and reads a project', async () => {
    const db = await createDb(':memory:');
    const [created] = await db.insert(projects).values({
      name: 'test-project',
      path: '/tmp/test',
    }).returning();

    expect(created.name).toBe('test-project');
    expect(created.path).toBe('/tmp/test');
    expect(created.id).toBeDefined();

    const [found] = await db.select().from(projects).where(eq(projects.id, created.id));
    expect(found.name).toBe('test-project');
  });

  it('inserts and reads an agent', async () => {
    const db = await createDb(':memory:');
    const [project] = await db.insert(projects).values({ name: 'p1' }).returning();
    const [agent] = await db.insert(agents).values({
      projectId: project.id,
      name: 'backend-lead',
      adapterType: 'claude_local',
    }).returning();

    expect(agent.name).toBe('backend-lead');
    expect(agent.status).toBe('idle');
    expect(agent.adapterType).toBe('claude_local');
  });

  it('inserts conventions', async () => {
    const db = await createDb(':memory:');
    const [project] = await db.insert(projects).values({ name: 'p2' }).returning();
    const [conv] = await db.insert(conventions).values({
      projectId: project.id,
      category: 'code-style',
      rule: 'no-force-push',
      scope: 'global',
    }).returning();

    expect(conv.category).toBe('code-style');
    expect(conv.enabled).toBe(true);
  });

  it('inserts guardrails', async () => {
    const db = await createDb(':memory:');
    const [project] = await db.insert(projects).values({ name: 'p3' }).returning();
    const [guard] = await db.insert(guardrails).values({
      projectId: project.id,
      key: 'max_files_changed',
      value: '20',
    }).returning();

    expect(guard.key).toBe('max_files_changed');
    expect(guard.value).toBe('20');
  });

  it('inserts tasks', async () => {
    const db = await createDb(':memory:');
    const [project] = await db.insert(projects).values({ name: 'p4' }).returning();
    const [task] = await db.insert(tasks).values({
      projectId: project.id,
      title: 'Implement rate limiter',
    }).returning();

    expect(task.title).toBe('Implement rate limiter');
    expect(task.status).toBe('todo');
  });

  it('cascade deletes agents when project is deleted', async () => {
    const db = await createDb(':memory:');
    const [project] = await db.insert(projects).values({ name: 'p5' }).returning();
    await db.insert(agents).values({ projectId: project.id, name: 'a1', adapterType: 'claude_local' });

    await db.delete(projects).where(eq(projects.id, project.id));
    const remainingAgents = await db.select().from(agents).where(eq(agents.projectId, project.id));
    expect(remainingAgents).toHaveLength(0);
  });
});
