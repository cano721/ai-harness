import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, rm, writeFile, mkdir, readFile } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import {
  createSnapshot,
  listSnapshots,
  restoreSnapshot,
  restoreLatest,
} from '../../src/engine/snapshot-manager.js';

let tempDir: string;
let harnessDir: string;

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), 'ai-harness-snap-test-'));
  harnessDir = join(tempDir, '.ai-harness');
  await mkdir(harnessDir, { recursive: true });
  await mkdir(join(harnessDir, 'hooks'), { recursive: true });

  // 기본 파일 생성
  await writeFile(join(harnessDir, 'config.yaml'), '_schema_version: 1\nteams: []\n', 'utf-8');
  await writeFile(join(harnessDir, 'hooks', 'block-dangerous.sh'), '#!/bin/bash\necho "block"', 'utf-8');
  await writeFile(join(tempDir, 'CLAUDE.md'), '# Test CLAUDE.md\n', 'utf-8');
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('snapshot-manager', () => {
  describe('createSnapshot', () => {
    it('스냅샷을 생성하고 ID(timestamp)를 반환한다', async () => {
      const id = await createSnapshot(harnessDir);
      expect(id).toBeTruthy();
      expect(typeof id).toBe('string');
    });

    it('스냅샷 디렉토리에 metadata.json이 생성된다', async () => {
      const id = await createSnapshot(harnessDir);
      const metaPath = join(harnessDir, 'snapshots', id, 'metadata.json');
      expect(existsSync(metaPath)).toBe(true);

      const raw = await readFile(metaPath, 'utf-8');
      const meta = JSON.parse(raw) as { createdAt: string; files: string[] };
      expect(meta.createdAt).toBeTruthy();
      expect(Array.isArray(meta.files)).toBe(true);
      expect(meta.files.length).toBeGreaterThan(0);
    });

    it('config.yaml이 스냅샷에 포함된다', async () => {
      const id = await createSnapshot(harnessDir);
      const snapshotConfig = join(harnessDir, 'snapshots', id, 'config.yaml');
      expect(existsSync(snapshotConfig)).toBe(true);
    });

    it('hooks 디렉토리가 스냅샷에 포함된다', async () => {
      const id = await createSnapshot(harnessDir);
      const snapshotHook = join(harnessDir, 'snapshots', id, 'hooks', 'block-dangerous.sh');
      expect(existsSync(snapshotHook)).toBe(true);
    });
  });

  describe('listSnapshots', () => {
    it('스냅샷이 없을 때 빈 배열을 반환한다', async () => {
      const snapshots = await listSnapshots(harnessDir);
      expect(snapshots).toEqual([]);
    });

    it('복수 스냅샷 목록을 반환한다', async () => {
      await createSnapshot(harnessDir);
      // 1ms 간격을 두어 다른 ID 생성
      await new Promise((r) => setTimeout(r, 5));
      await createSnapshot(harnessDir);

      const snapshots = await listSnapshots(harnessDir);
      expect(snapshots.length).toBeGreaterThanOrEqual(2);
    });

    it('각 스냅샷에 id, createdAt, files 필드가 있다', async () => {
      await createSnapshot(harnessDir);
      const snapshots = await listSnapshots(harnessDir);
      expect(snapshots.length).toBeGreaterThan(0);

      const snap = snapshots[0];
      expect(snap.id).toBeTruthy();
      expect(snap.createdAt).toBeTruthy();
      expect(Array.isArray(snap.files)).toBe(true);
    });

    it('스냅샷이 id(timestamp) 기준으로 정렬된다', async () => {
      await createSnapshot(harnessDir);
      await new Promise((r) => setTimeout(r, 5));
      await createSnapshot(harnessDir);

      const snapshots = await listSnapshots(harnessDir);
      if (snapshots.length >= 2) {
        expect(snapshots[0].id.localeCompare(snapshots[1].id)).toBeLessThanOrEqual(0);
      }
    });
  });

  describe('restoreSnapshot', () => {
    it('복원 후 파일 내용이 스냅샷과 일치한다', async () => {
      const originalContent = '_schema_version: 1\nteams: [backend]\n';
      await writeFile(join(harnessDir, 'config.yaml'), originalContent, 'utf-8');

      const id = await createSnapshot(harnessDir);

      // 파일을 수정
      await writeFile(join(harnessDir, 'config.yaml'), '_schema_version: 1\nteams: [frontend]\n', 'utf-8');

      await restoreSnapshot(harnessDir, id);

      const restored = await readFile(join(harnessDir, 'config.yaml'), 'utf-8');
      expect(restored).toBe(originalContent);
    });

    it('존재하지 않는 스냅샷 ID는 오류를 던진다', async () => {
      await expect(restoreSnapshot(harnessDir, 'nonexistent-id')).rejects.toThrow();
    });
  });

  describe('restoreLatest', () => {
    it('스냅샷이 없을 때 null을 반환한다', async () => {
      const result = await restoreLatest(harnessDir);
      expect(result).toBeNull();
    });

    it('최신 스냅샷 ID를 반환하고 복원한다', async () => {
      const originalContent = '_schema_version: 1\nteams: [devops]\n';
      await writeFile(join(harnessDir, 'config.yaml'), originalContent, 'utf-8');

      await createSnapshot(harnessDir);

      // 파일 수정
      await writeFile(join(harnessDir, 'config.yaml'), '_schema_version: 1\nteams: []\n', 'utf-8');

      const restoredId = await restoreLatest(harnessDir);
      expect(restoredId).toBeTruthy();

      const restored = await readFile(join(harnessDir, 'config.yaml'), 'utf-8');
      expect(restored).toBe(originalContent);
    });

    it('복수 스냅샷 중 가장 마지막 스냅샷으로 복원한다', async () => {
      await writeFile(join(harnessDir, 'config.yaml'), 'teams: [first]\n', 'utf-8');
      await createSnapshot(harnessDir);

      await new Promise((r) => setTimeout(r, 5));

      await writeFile(join(harnessDir, 'config.yaml'), 'teams: [second]\n', 'utf-8');
      await createSnapshot(harnessDir);

      // 파일 변경
      await writeFile(join(harnessDir, 'config.yaml'), 'teams: [third]\n', 'utf-8');

      await restoreLatest(harnessDir);

      const restored = await readFile(join(harnessDir, 'config.yaml'), 'utf-8');
      expect(restored).toBe('teams: [second]\n');
    });
  });
});
