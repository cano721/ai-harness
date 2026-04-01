import { existsSync } from 'fs';
import { resolve } from 'path';
import { APP_NAME, migrateFromAiHarness } from '@ddalkak/shared';

export async function migrateCommand(args: string[]) {
  const projectPath = resolve(args[0] ?? '.');

  console.log(`\n  ⚡ ${APP_NAME} migrate\n`);
  console.log(`  Project path: ${projectPath}`);

  if (!existsSync(projectPath)) {
    console.error(`  Path not found: ${projectPath}`);
    process.exit(1);
  }

  const { migrated, details } = await migrateFromAiHarness(projectPath);

  if (!migrated) {
    console.log(`  No .ai-harness/ directory found. Nothing to migrate.\n`);
    process.exit(0);
  }

  console.log(`\n  Migration complete:`);
  for (const d of details) {
    console.log(`    ✓ ${d}`);
  }
  console.log(`\n  Original .ai-harness/ preserved (not deleted).`);
  console.log(`  Review .ddalkak/ and commit when ready.\n`);
}
