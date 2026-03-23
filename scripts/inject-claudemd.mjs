#!/usr/bin/env node
import fs from 'fs';

const START_MARKER = '<!-- harness:start -->';
const END_MARKER = '<!-- harness:end -->';

function hasHarnessSection(content) {
  return content.includes(START_MARKER) && content.includes(END_MARKER);
}

function inject(claudeMdPath, contentFile) {
  const newContent = fs.readFileSync(contentFile, 'utf-8');
  let existing = fs.existsSync(claudeMdPath) ? fs.readFileSync(claudeMdPath, 'utf-8') : '';

  const section = `${START_MARKER}\n${newContent}\n${END_MARKER}`;

  if (hasHarnessSection(existing)) {
    const before = existing.indexOf(START_MARKER);
    const after = existing.indexOf(END_MARKER) + END_MARKER.length;
    existing = existing.slice(0, before) + section + existing.slice(after);
  } else {
    existing = existing ? existing + '\n\n' + section : section;
  }

  fs.writeFileSync(claudeMdPath, existing, 'utf-8');
  console.log(`주입 완료: ${claudeMdPath}`);
}

function remove(claudeMdPath) {
  if (!fs.existsSync(claudeMdPath)) {
    console.error(`파일 없음: ${claudeMdPath}`);
    process.exit(1);
  }
  let content = fs.readFileSync(claudeMdPath, 'utf-8');
  if (!hasHarnessSection(content)) {
    console.log('harness 구간 없음, 변경 없이 종료.');
    return;
  }
  const before = content.indexOf(START_MARKER);
  const after = content.indexOf(END_MARKER) + END_MARKER.length;
  content = (content.slice(0, before) + content.slice(after)).replace(/\n{3,}/g, '\n\n').trim();
  fs.writeFileSync(claudeMdPath, content, 'utf-8');
  console.log(`harness 구간 제거 완료: ${claudeMdPath}`);
}

function check(claudeMdPath) {
  if (!fs.existsSync(claudeMdPath)) {
    process.exit(1);
  }
  const content = fs.readFileSync(claudeMdPath, 'utf-8');
  if (hasHarnessSection(content)) {
    console.log('harness 구간 존재');
    process.exit(0);
  } else {
    console.log('harness 구간 없음');
    process.exit(1);
  }
}

const [,, cmd, claudeMdPath, contentFile] = process.argv;

if (!cmd || !claudeMdPath) {
  console.error('사용법:');
  console.error('  node scripts/inject-claudemd.mjs inject <claudeMdPath> <contentFile>');
  console.error('  node scripts/inject-claudemd.mjs remove <claudeMdPath>');
  console.error('  node scripts/inject-claudemd.mjs check <claudeMdPath>');
  process.exit(1);
}

try {
  if (cmd === 'inject') {
    if (!contentFile) {
      console.error('inject에는 contentFile이 필요합니다.');
      process.exit(1);
    }
    inject(claudeMdPath, contentFile);
  } else if (cmd === 'remove') {
    remove(claudeMdPath);
  } else if (cmd === 'check') {
    check(claudeMdPath);
  } else {
    console.error(`알 수 없는 명령: ${cmd}`);
    process.exit(1);
  }
} catch (err) {
  console.error(`오류: ${err.message}`);
  process.exit(1);
}
