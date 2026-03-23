import { readFile, writeFile, mkdir, readdir, copyFile, stat } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';

export interface SnapshotInfo {
  id: string;
  createdAt: string;
  files: string[];
}

const SNAPSHOTS_DIR = 'snapshots';

function snapshotsDir(harnessDir: string): string {
  return join(harnessDir, SNAPSHOTS_DIR);
}

async function collectFiles(harnessDir: string): Promise<string[]> {
  const files: string[] = [];

  // config.yaml
  const configPath = join(harnessDir, 'config.yaml');
  if (existsSync(configPath)) files.push('config.yaml');

  // lock-policy.yaml
  const lockPath = join(harnessDir, 'lock-policy.yaml');
  if (existsSync(lockPath)) files.push('lock-policy.yaml');

  // CLAUDE.md (project root, one level up from harnessDir)
  const projectRoot = join(harnessDir, '..');
  const claudeMdPath = join(projectRoot, 'CLAUDE.md');
  if (existsSync(claudeMdPath)) files.push('../CLAUDE.md');

  // hooks/
  const hooksDir = join(harnessDir, 'hooks');
  if (existsSync(hooksDir)) {
    const hookFiles = await readdir(hooksDir);
    for (const f of hookFiles) {
      files.push(join('hooks', f));
    }
  }

  return files;
}

export async function createSnapshot(harnessDir: string): Promise<string> {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '').replace('Z', '');
  const snapshotPath = join(snapshotsDir(harnessDir), timestamp);

  await mkdir(snapshotPath, { recursive: true });
  await mkdir(join(snapshotPath, 'hooks'), { recursive: true });

  const files = await collectFiles(harnessDir);
  const copiedFiles: string[] = [];

  for (const relPath of files) {
    const srcPath = relPath.startsWith('..')
      ? join(harnessDir, relPath)
      : join(harnessDir, relPath);

    if (!existsSync(srcPath)) continue;

    // flatten CLAUDE.md into snapshot root
    const destRelPath = relPath.startsWith('../') ? relPath.slice(3) : relPath;
    const destPath = join(snapshotPath, destRelPath);

    const destDir = join(destPath, '..');
    await mkdir(destDir, { recursive: true });
    await copyFile(srcPath, destPath);
    copiedFiles.push(destRelPath);
  }

  const metadata: { createdAt: string; files: string[] } = {
    createdAt: new Date().toISOString(),
    files: copiedFiles,
  };
  await writeFile(join(snapshotPath, 'metadata.json'), JSON.stringify(metadata, null, 2), 'utf-8');

  return timestamp;
}

export async function listSnapshots(harnessDir: string): Promise<SnapshotInfo[]> {
  const dir = snapshotsDir(harnessDir);
  if (!existsSync(dir)) return [];

  const entries = await readdir(dir);
  const snapshots: SnapshotInfo[] = [];

  for (const entry of entries) {
    const metaPath = join(dir, entry, 'metadata.json');
    if (!existsSync(metaPath)) continue;
    try {
      const raw = await readFile(metaPath, 'utf-8');
      const meta = JSON.parse(raw) as { createdAt: string; files: string[] };
      snapshots.push({ id: entry, createdAt: meta.createdAt, files: meta.files });
    } catch {
      // 손상된 스냅샷은 건너뜀
    }
  }

  return snapshots.sort((a, b) => a.id.localeCompare(b.id));
}

export async function restoreSnapshot(harnessDir: string, snapshotId: string): Promise<void> {
  const snapshotPath = join(snapshotsDir(harnessDir), snapshotId);
  if (!existsSync(snapshotPath)) {
    throw new Error(`스냅샷을 찾을 수 없습니다: ${snapshotId}`);
  }

  const metaPath = join(snapshotPath, 'metadata.json');
  const raw = await readFile(metaPath, 'utf-8');
  const meta = JSON.parse(raw) as { createdAt: string; files: string[] };

  for (const relPath of meta.files) {
    const srcPath = join(snapshotPath, relPath);
    if (!existsSync(srcPath)) continue;

    // CLAUDE.md는 프로젝트 루트에 복원
    const destPath = relPath === 'CLAUDE.md'
      ? join(harnessDir, '..', 'CLAUDE.md')
      : join(harnessDir, relPath);

    const destDir = join(destPath, '..');
    await mkdir(destDir, { recursive: true });
    await copyFile(srcPath, destPath);
  }
}

export async function restoreLatest(harnessDir: string): Promise<string | null> {
  const snapshots = await listSnapshots(harnessDir);
  if (snapshots.length === 0) return null;

  const latest = snapshots[snapshots.length - 1];
  await restoreSnapshot(harnessDir, latest.id);
  return latest.id;
}
