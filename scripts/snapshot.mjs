#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

const SNAPSHOTS_DIR = '.ai-harness/snapshots';

function getSnapshotsDir(harnessDir) {
  return path.join(harnessDir, SNAPSHOTS_DIR);
}

function copyDirRecursive(src, dest) {
  if (!fs.existsSync(src)) return;
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirRecursive(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

function createSnapshot(harnessDir) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const snapshotDir = path.join(getSnapshotsDir(harnessDir), timestamp);
  fs.mkdirSync(snapshotDir, { recursive: true });

  const configSrc = path.join(harnessDir, 'config.yaml');
  if (fs.existsSync(configSrc)) {
    fs.copyFileSync(configSrc, path.join(snapshotDir, 'config.yaml'));
  }

  const hooksSrc = path.join(harnessDir, 'hooks');
  if (fs.existsSync(hooksSrc)) {
    copyDirRecursive(hooksSrc, path.join(snapshotDir, 'hooks'));
  }

  console.log(JSON.stringify({ ok: true, snapshotId: timestamp, path: snapshotDir }));
}

function listSnapshots(harnessDir) {
  const snapshotsDir = getSnapshotsDir(harnessDir);
  if (!fs.existsSync(snapshotsDir)) {
    console.log(JSON.stringify([]));
    return;
  }
  const snapshots = fs.readdirSync(snapshotsDir)
    .filter(name => fs.statSync(path.join(snapshotsDir, name)).isDirectory())
    .sort();
  console.log(JSON.stringify(snapshots));
}

function restoreSnapshot(harnessDir, snapshotId) {
  const snapshotsDir = getSnapshotsDir(harnessDir);

  let targetId = snapshotId;
  if (!targetId) {
    if (!fs.existsSync(snapshotsDir)) {
      console.error('스냅샷 없음');
      process.exit(1);
    }
    const snapshots = fs.readdirSync(snapshotsDir)
      .filter(name => fs.statSync(path.join(snapshotsDir, name)).isDirectory())
      .sort();
    if (snapshots.length === 0) {
      console.error('스냅샷 없음');
      process.exit(1);
    }
    targetId = snapshots[snapshots.length - 1];
  }

  const snapshotDir = path.join(snapshotsDir, targetId);
  if (!fs.existsSync(snapshotDir)) {
    console.error(`스냅샷 없음: ${targetId}`);
    process.exit(1);
  }

  const configSrc = path.join(snapshotDir, 'config.yaml');
  if (fs.existsSync(configSrc)) {
    fs.copyFileSync(configSrc, path.join(harnessDir, 'config.yaml'));
  }

  const hooksSrc = path.join(snapshotDir, 'hooks');
  if (fs.existsSync(hooksSrc)) {
    copyDirRecursive(hooksSrc, path.join(harnessDir, 'hooks'));
  }

  console.log(JSON.stringify({ ok: true, restored: targetId }));
}

const [,, cmd, harnessDir, snapshotId] = process.argv;

if (!cmd || !harnessDir) {
  console.error('사용법:');
  console.error('  node scripts/snapshot.mjs create <harnessDir>');
  console.error('  node scripts/snapshot.mjs restore <harnessDir> [snapshotId]');
  console.error('  node scripts/snapshot.mjs list <harnessDir>');
  process.exit(1);
}

try {
  if (cmd === 'create') {
    createSnapshot(harnessDir);
  } else if (cmd === 'restore') {
    restoreSnapshot(harnessDir, snapshotId);
  } else if (cmd === 'list') {
    listSnapshots(harnessDir);
  } else {
    console.error(`알 수 없는 명령: ${cmd}`);
    process.exit(1);
  }
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
