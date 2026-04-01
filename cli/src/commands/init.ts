import { existsSync } from 'fs';
import { resolve } from 'path';
import {
  APP_NAME,
  ensureDdalkakDir,
  writeConfig,
  detectTechStack,
  isGitRepo,
  getGitUrl,
  ddalkakDirExists,
} from '@ddalkak/shared';

export async function initCommand(args: string[]) {
  const projectPath = resolve(args[0] ?? '.');

  if (!existsSync(projectPath)) {
    console.error(`  Path not found: ${projectPath}`);
    process.exit(1);
  }

  console.log(`\n  ⚡ ${APP_NAME} init\n`);
  console.log(`  Project path: ${projectPath}`);

  if (await ddalkakDirExists(projectPath)) {
    console.log('  .ddalkak/ already exists. Skipping init.');
    process.exit(0);
  }

  // Detect
  const git = isGitRepo(projectPath);
  const gitUrl = git ? getGitUrl(projectPath) : undefined;
  const techStack = await detectTechStack(projectPath);

  console.log(`  Git repo: ${git ? 'yes' : 'no'}${gitUrl ? ` (${gitUrl})` : ''}`);
  console.log(`  Tech stack: ${techStack.length ? techStack.join(', ') : 'unknown'}`);

  // Create .ddalkak/
  await ensureDdalkakDir(projectPath);

  const name = projectPath.split('/').pop() ?? 'project';
  await writeConfig(projectPath, {
    name,
    gitUrl,
    techStack,
    guardrails: {
      max_files_changed: 20,
      max_execution_minutes: 30,
    },
  });

  console.log(`\n  Created .ddalkak/ with:`);
  console.log(`    - config.yaml`);
  console.log(`    - agents/`);
  console.log(`    - skills/`);
  console.log(`    - hooks/`);
  console.log(`\n  Done! Commit .ddalkak/ to share with your team.\n`);
}
