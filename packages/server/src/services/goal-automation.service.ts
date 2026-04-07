import {
  createDb,
  goals,
  projectAutomationRoutines,
  tasks,
  activityLog,
} from '@ddalkak/db';
import { and, eq, inArray } from 'drizzle-orm';
import type {
  Goal,
  GoalStatus,
  ProjectAutomationRunResult,
  ProjectAutomationTaskStage,
  TaskGoalAutomationMetadata,
} from '@ddalkak/shared';

type GoalRow = typeof goals.$inferSelect;
type RoutineRow = typeof projectAutomationRoutines.$inferSelect;
type TaskRow = typeof tasks.$inferSelect;

const STAGE_LABELS: Record<ProjectAutomationTaskStage, string> = {
  implement: 'implementation',
  review: 'review',
  verify: 'verification',
};

function getTaskGoalAutomationMetadata(task: TaskRow): TaskGoalAutomationMetadata | null {
  const metadata = task.metadata as { goalAutomation?: TaskGoalAutomationMetadata } | null | undefined;
  if (!metadata?.goalAutomation?.goalId || !metadata.goalAutomation.stage) {
    return null;
  }
  return metadata.goalAutomation;
}

function getRequiredStages(routine: RoutineRow): ProjectAutomationTaskStage[] {
  const stages: ProjectAutomationTaskStage[] = ['implement'];
  if (routine.reviewerAgentId) stages.push('review');
  if (routine.verifierAgentId) stages.push('verify');
  return stages;
}

function getStageAgentId(routine: RoutineRow, stage: ProjectAutomationTaskStage) {
  if (stage === 'implement') return routine.developerAgentId;
  if (stage === 'review') return routine.reviewerAgentId;
  return routine.verifierAgentId;
}

function buildTaskTitle(goal: GoalRow, stage: ProjectAutomationTaskStage) {
  if (stage === 'implement') return `Advance ${goal.title}`;
  if (stage === 'review') return `Review ${goal.title}`;
  return `Verify ${goal.title}`;
}

function buildTaskDescription(goal: GoalRow, stage: ProjectAutomationTaskStage) {
  const lines = [
    `Goal: ${goal.title}`,
    `Stage: ${STAGE_LABELS[stage]}`,
  ];
  if (goal.description) {
    lines.push('', goal.description);
  }
  return lines.join('\n');
}

function deriveParentGoalStatus(childStatuses: GoalStatus[]): GoalStatus {
  if (childStatuses.length === 0) return 'planned';
  if (childStatuses.every((status) => status === 'achieved')) return 'achieved';
  if (childStatuses.some((status) => status === 'blocked')) return 'blocked';
  if (childStatuses.some((status) => status === 'active' || status === 'achieved')) return 'active';
  return 'planned';
}

function buildChildrenByParent(goalsList: GoalRow[]): Map<string, GoalRow[]> {
  const childrenByParent = new Map<string, GoalRow[]>();
  for (const goal of goalsList) {
    if (!goal.parentGoalId) continue;
    const current = childrenByParent.get(goal.parentGoalId) ?? [];
    childrenByParent.set(goal.parentGoalId, [...current, goal]);
  }
  return childrenByParent;
}

function deriveHierarchyStatus(
  goalId: string,
  childrenByParent: Map<string, GoalRow[]>,
  goalStatusById: Map<string, GoalStatus>,
  visiting = new Set<string>(),
): GoalStatus {
  if (visiting.has(goalId)) {
    return goalStatusById.get(goalId) ?? 'planned';
  }

  const children = childrenByParent.get(goalId);
  if (!children || children.length === 0) {
    return goalStatusById.get(goalId) ?? 'planned';
  }

  visiting.add(goalId);
  const childStatuses = children.map((child) =>
    deriveHierarchyStatus(child.id, childrenByParent, goalStatusById, visiting),
  );
  visiting.delete(goalId);

  const nextStatus = deriveParentGoalStatus(childStatuses);
  goalStatusById.set(goalId, nextStatus);
  return nextStatus;
}

function isRoutineDue(routine: RoutineRow, now = new Date()): boolean {
  const intervalMinutes = Math.max(1, routine.heartbeatMinutes ?? 1);
  if (!routine.lastEvaluatedAt) return true;

  const lastEvaluatedAt = routine.lastEvaluatedAt instanceof Date
    ? routine.lastEvaluatedAt
    : new Date(routine.lastEvaluatedAt);
  if (Number.isNaN(lastEvaluatedAt.getTime())) return true;

  return now.getTime() - lastEvaluatedAt.getTime() >= intervalMinutes * 60_000;
}

async function logAutomationActivity(projectId: string, eventType: string, detail: Record<string, unknown>) {
  const db = await createDb();
  await db.insert(activityLog).values({
    projectId,
    eventType,
    detail,
  });
}

export async function evaluateProjectAutomation(projectId: string): Promise<ProjectAutomationRunResult> {
  const db = await createDb();
  const [routine] = await db
    .select()
    .from(projectAutomationRoutines)
    .where(eq(projectAutomationRoutines.projectId, projectId));

  const evaluatedAt = new Date().toISOString();
  if (!routine) {
    return {
      projectId,
      routineId: null,
      evaluatedAt,
      createdTasks: [],
      updatedGoals: [],
      skippedGoals: [],
      summary: 'No automation routine configured for this project.',
    };
  }

  if (routine.status !== 'active') {
    return {
      projectId,
      routineId: routine.id,
      evaluatedAt,
      createdTasks: [],
      updatedGoals: [],
      skippedGoals: [],
      summary: 'Automation routine is paused.',
    };
  }

  const allGoals = await db.select().from(goals).where(eq(goals.projectId, projectId));
  const allTasks = await db.select().from(tasks).where(eq(tasks.projectId, projectId));
  const childrenByParent = buildChildrenByParent(allGoals);

  const leafGoals = allGoals.filter((goal) => !childrenByParent.has(goal.id));
  const createdTasks: ProjectAutomationRunResult['createdTasks'] = [];
  const updatedGoals: ProjectAutomationRunResult['updatedGoals'] = [];
  const skippedGoals: ProjectAutomationRunResult['skippedGoals'] = [];
  const goalStatusById = new Map(allGoals.map((goal) => [goal.id, goal.status as GoalStatus]));
  const requiredStages = getRequiredStages(routine);

  for (const goal of leafGoals) {
    const currentGoalStatus = goalStatusById.get(goal.id) ?? (goal.status as GoalStatus);
    if (currentGoalStatus === 'achieved' || currentGoalStatus === 'blocked') {
      continue;
    }

    const goalTasks = allTasks.filter((task) => getTaskGoalAutomationMetadata(task)?.goalId === goal.id);
    const openTasks = goalTasks.filter((task) => task.status !== 'done');
    const completedStages = new Set<ProjectAutomationTaskStage>(
      goalTasks
        .filter((task) => task.status === 'done')
        .map((task) => getTaskGoalAutomationMetadata(task)?.stage)
        .filter((stage): stage is ProjectAutomationTaskStage => !!stage),
    );

    if (requiredStages.every((stage) => completedStages.has(stage))) {
      await db
        .update(goals)
        .set({ status: 'achieved', updatedAt: new Date() })
        .where(and(eq(goals.id, goal.id), eq(goals.projectId, projectId)));
      goalStatusById.set(goal.id, 'achieved');
      updatedGoals.push({ goalId: goal.id, status: 'achieved' });
      await logAutomationActivity(projectId, 'goal.automation.goal_achieved', {
        goalId: goal.id,
        goalTitle: goal.title,
      });
      continue;
    }

    if (openTasks.length > 0) {
      if (currentGoalStatus !== 'active') {
        await db
          .update(goals)
          .set({ status: 'active', updatedAt: new Date() })
          .where(and(eq(goals.id, goal.id), eq(goals.projectId, projectId)));
        goalStatusById.set(goal.id, 'active');
        updatedGoals.push({ goalId: goal.id, status: 'active' });
      }
      continue;
    }

    const nextStage = requiredStages.find((stage) => !completedStages.has(stage));
    if (!nextStage) continue;
    const agentId = getStageAgentId(routine, nextStage);

    if (!agentId) {
      skippedGoals.push({
        goalId: goal.id,
        reason: `No ${nextStage} agent configured for goal ${goal.title}.`,
      });
      await logAutomationActivity(projectId, 'goal.automation.skipped', {
        goalId: goal.id,
        goalTitle: goal.title,
        stage: nextStage,
        reason: `No ${nextStage} agent configured.`,
      });
      continue;
    }

    const taskTitle = buildTaskTitle(goal, nextStage);
    const taskDescription = buildTaskDescription(goal, nextStage);
    const [createdTask] = await db.insert(tasks).values({
      projectId,
      agentId,
      title: taskTitle,
      description: taskDescription,
      status: 'todo',
      metadata: {
        goalAutomation: {
          goalId: goal.id,
          goalTitle: goal.title,
          stage: nextStage,
          routineId: routine.id,
          createdBy: 'goal-automation',
        },
      },
    }).returning();

    createdTasks.push({
      taskId: createdTask.id,
      goalId: goal.id,
      goalTitle: goal.title,
      stage: nextStage,
      agentId,
      title: createdTask.title,
    });
    allTasks.push(createdTask);

    if (currentGoalStatus !== 'active') {
      await db
        .update(goals)
        .set({ status: 'active', updatedAt: new Date() })
        .where(and(eq(goals.id, goal.id), eq(goals.projectId, projectId)));
      goalStatusById.set(goal.id, 'active');
      updatedGoals.push({ goalId: goal.id, status: 'active' });
    }

    await logAutomationActivity(projectId, 'goal.automation.task_created', {
      goalId: goal.id,
      goalTitle: goal.title,
      taskId: createdTask.id,
      taskTitle: createdTask.title,
      stage: nextStage,
      agentId,
    });
  }

  const previousGoalStatusById = new Map(goalStatusById);
  const parentGoalIds = [...childrenByParent.keys()];
  for (const goalId of parentGoalIds) {
    const nextStatus = deriveHierarchyStatus(goalId, childrenByParent, goalStatusById);
    const currentStatus = previousGoalStatusById.get(goalId);
    if (currentStatus && currentStatus !== nextStatus) {
      await db
        .update(goals)
        .set({ status: nextStatus, updatedAt: new Date() })
        .where(and(eq(goals.id, goalId), eq(goals.projectId, projectId)));
      goalStatusById.set(goalId, nextStatus);
      updatedGoals.push({ goalId, status: nextStatus });
    }
  }

  await db.update(projectAutomationRoutines)
    .set({ lastEvaluatedAt: new Date(), updatedAt: new Date() })
    .where(eq(projectAutomationRoutines.id, routine.id));

  await logAutomationActivity(projectId, 'goal.automation.evaluated', {
    routineId: routine.id,
    createdTaskCount: createdTasks.length,
    updatedGoalCount: updatedGoals.length,
    skippedGoalCount: skippedGoals.length,
  });

  return {
    projectId,
    routineId: routine.id,
    evaluatedAt,
    createdTasks,
    updatedGoals,
    skippedGoals,
    summary:
      createdTasks.length > 0
        ? `Created ${createdTasks.length} automation task(s).`
        : skippedGoals.length > 0
          ? `No tasks created. ${skippedGoals.length} goal(s) are waiting on agent configuration.`
          : 'Automation check completed without new tasks.',
  };
}

export async function runActiveGoalAutomations(): Promise<void> {
  const db = await createDb();
  const activeRoutines = await db
    .select()
    .from(projectAutomationRoutines)
    .where(eq(projectAutomationRoutines.status, 'active'));

  const dueRoutines = activeRoutines.filter((routine) => isRoutineDue(routine));
  if (dueRoutines.length === 0) return;

  const projectIds = dueRoutines.map((routine) => routine.projectId);
  const existingGoals = await db.select().from(goals).where(inArray(goals.projectId, projectIds));
  const existingGoalSet = new Set(existingGoals.map((goal) => goal.projectId));

  for (const routine of dueRoutines) {
    if (!existingGoalSet.has(routine.projectId)) continue;
    await evaluateProjectAutomation(routine.projectId);
  }
}

export async function getProjectGoals(projectId: string): Promise<Goal[]> {
  const db = await createDb();
  const result = await db.select().from(goals).where(eq(goals.projectId, projectId));
  return result.map((goal) => ({
    ...goal,
    status: goal.status as GoalStatus,
  }));
}

export async function getProjectAutomationRoutine(projectId: string) {
  const db = await createDb();
  const [routine] = await db
    .select()
    .from(projectAutomationRoutines)
    .where(eq(projectAutomationRoutines.projectId, projectId));
  return routine ?? null;
}

export async function syncGoalHierarchyForProject(projectId: string) {
  const db = await createDb();
  const projectGoals = await db.select().from(goals).where(eq(goals.projectId, projectId));
  const childrenByParent = buildChildrenByParent(projectGoals);
  const currentGoalStatusById = new Map(projectGoals.map((goal) => [goal.id, goal.status as GoalStatus]));
  const nextGoalStatusById = new Map(currentGoalStatusById);

  for (const parentGoalId of childrenByParent.keys()) {
    deriveHierarchyStatus(parentGoalId, childrenByParent, nextGoalStatusById);
  }

  for (const parentGoalId of childrenByParent.keys()) {
    const currentStatus = currentGoalStatusById.get(parentGoalId);
    const nextStatus = nextGoalStatusById.get(parentGoalId);
    if (!currentStatus || !nextStatus || currentStatus === nextStatus) {
      continue;
    }

    await db
      .update(goals)
      .set({ status: nextStatus, updatedAt: new Date() })
      .where(and(eq(goals.id, parentGoalId), eq(goals.projectId, projectId)));
  }
}
