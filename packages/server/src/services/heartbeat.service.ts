import { createDb, agents, activityLog } from '@ddalkak/db';
import { eq, and, lt, isNotNull } from 'drizzle-orm';
import { HEARTBEAT_INTERVAL_MS, HEARTBEAT_TIMEOUT_MS } from '@ddalkak/shared';

export class HeartbeatService {
  private timer: ReturnType<typeof setInterval> | null = null;

  start(intervalMs = HEARTBEAT_INTERVAL_MS): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.checkTimeouts(), intervalMs);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  async checkTimeouts(): Promise<void> {
    const db = await createDb();
    const cutoff = new Date(Date.now() - HEARTBEAT_TIMEOUT_MS);

    const timedOut = await db
      .select()
      .from(agents)
      .where(
        and(
          eq(agents.status, 'running'),
          isNotNull(agents.lastHeartbeat),
          lt(agents.lastHeartbeat, cutoff),
        ),
      );

    for (const agent of timedOut) {
      await db
        .update(agents)
        .set({ status: 'error' })
        .where(eq(agents.id, agent.id));

      await db.insert(activityLog).values({
        projectId: agent.projectId,
        agentId: agent.id,
        eventType: 'agent.timeout',
        detail: {
          agentName: agent.name,
          lastHeartbeat: agent.lastHeartbeat,
          timeoutMs: HEARTBEAT_TIMEOUT_MS,
        },
      });
    }
  }
}

export const heartbeatService = new HeartbeatService();
