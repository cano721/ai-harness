import { existsSync } from 'fs';
import { resolve } from 'path';
import { APP_NAME, migrateFromAiHarness } from '@ddalkak/shared';

export async function migrateCommand(args: string[]) {
  const dryRun = args.includes('--dry-run');
  const force = args.includes('--force');
  const positional = args.filter(a => !a.startsWith('--'));
  const projectPath = resolve(positional[0] ?? '.');

  console.log(`\n  ⚡ ${APP_NAME} migrate\n`);
  console.log(`  Project path: ${projectPath}`);
  if (dryRun) console.log('  Mode: dry-run (no files will be written)');
  if (force) console.log('  Mode: force (existing files will be overwritten)');
  console.log('');

  if (!existsSync(projectPath)) {
    console.error(`  Path not found: ${projectPath}`);
    process.exit(1);
  }

  const { migrated, details } = await migrateFromAiHarness(projectPath, { dryRun, force });

  if (!migrated) {
    console.log('  No .ai-harness/ directory found. Nothing to migrate.\n');
    process.exit(0);
  }

  const migratedCount = details.filter(d => d.status === 'migrated').length;
  const skippedCount = details.filter(d => d.status === 'skipped').length;
  const errorCount = details.filter(d => d.status === 'error').length;

  console.log(dryRun ? '  Planned changes:' : '  Migration complete:');

  for (const d of details) {
    const icon = d.status === 'migrated' ? '✓' : d.status === 'skipped' ? '~' : '✗';
    console.log(`    ${icon} ${d.message}`);
  }

  console.log('');
  console.log(`  Summary: ${migratedCount} migrated, ${skippedCount} skipped, ${errorCount} errors`);

  if (!dryRun) {
    console.log('  Original .ai-harness/ preserved (not deleted).');
    console.log('  Review .ddalkak/ and commit when ready.');
    if (skippedCount > 0) {
      console.log('  Tip: use --force to overwrite existing files.');
    }
  }
  console.log('');
}
