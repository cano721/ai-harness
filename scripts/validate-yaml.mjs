#!/usr/bin/env node

import { readFileSync } from 'fs';
import { execSync } from 'child_process';
import { parse } from 'yaml';

const files = execSync('find . -name "*.yaml" -o -name "*.yml" | grep -v node_modules', {
  encoding: 'utf8'
}).trim().split('\n').filter(Boolean);

let errors = 0;

for (const file of files) {
  try {
    parse(readFileSync(file, 'utf8'));
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
