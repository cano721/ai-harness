#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

function copyFile(src, dest) {
  const destDir = path.dirname(dest);
  if (!fs.existsSync(destDir)) {
    fs.mkdirSync(destDir, { recursive: true });
  }
  fs.copyFileSync(src, dest);
  return dest;
}

function copyTeamResources(team, sourceDir, destDir) {
  const srcTeamDir = path.join(sourceDir, 'teams', team);
  const destTeamDir = path.join(destDir, 'teams', team);
  const copied = [];

  if (!fs.existsSync(srcTeamDir)) {
    console.error(`소스 팀 디렉토리 없음: ${srcTeamDir}`);
    process.exit(1);
  }

  const hooksDir = path.join(srcTeamDir, 'hooks');
  if (fs.existsSync(hooksDir)) {
    for (const file of fs.readdirSync(hooksDir)) {
      const src = path.join(hooksDir, file);
      const dest = path.join(destTeamDir, 'hooks', file);
      copyFile(src, dest);
      if (file.endsWith('.sh')) {
        fs.chmodSync(dest, 0o755);
      }
      copied.push(dest);
    }
  }

  const skillsDir = path.join(srcTeamDir, 'skills');
  if (fs.existsSync(skillsDir)) {
    for (const file of fs.readdirSync(skillsDir)) {
      if (file.endsWith('.md')) {
        const src = path.join(skillsDir, file);
        const dest = path.join(destTeamDir, 'skills', file);
        copyFile(src, dest);
        copied.push(dest);
      }
    }
  }

  const claudeMd = path.join(srcTeamDir, 'CLAUDE.md');
  if (fs.existsSync(claudeMd)) {
    const dest = path.join(destTeamDir, 'CLAUDE.md');
    copyFile(claudeMd, dest);
    copied.push(dest);
  }

  console.log(JSON.stringify({ ok: true, team, copied }));
}

const [,, team, sourceDir, destDir] = process.argv;

if (!team || !sourceDir || !destDir) {
  console.error('사용법:');
  console.error('  node scripts/copy-team-resources.mjs <team> <sourceDir> <destDir>');
  process.exit(1);
}

try {
  copyTeamResources(team, sourceDir, destDir);
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
