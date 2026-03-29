#!/usr/bin/env node

import { readFileSync, readdirSync } from 'fs';
import { join, extname } from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
let yaml;
try {
  yaml = require('yaml');
} catch {
  console.error('yaml 패키지가 필요합니다: npm install yaml');
  process.exit(1);
}

const IGNORE_DIRS = new Set(['node_modules', '.git', '.omc', 'dist']);

function findYamlFiles(dir) {
  const results = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (IGNORE_DIRS.has(entry.name)) continue;
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findYamlFiles(fullPath));
    } else if (entry.isFile() && (extname(entry.name) === '.yaml' || extname(entry.name) === '.yml')) {
      results.push(fullPath);
    }
  }
  return results;
}

const files = findYamlFiles('.');
let errors = 0;

for (const file of files) {
  try {
    yaml.parse(readFileSync(file, 'utf8'));
    console.log('OK:', file);
  } catch (e) {
    console.error('FAIL:', file, '-', e.message);
    errors++;
  }
}

if (errors > 0) {
  console.error(`\n${errors} file(s) failed validation.`);
  process.exit(1);
} else {
  console.log(`\n${files.length} file(s) validated successfully.`);
}
