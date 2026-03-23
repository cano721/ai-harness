#!/usr/bin/env node
import { execSync } from 'child_process';

function runCommand(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf-8', timeout: 5000 }).trim();
  } catch {
    return null;
  }
}

function parseVersion(output) {
  if (!output) return null;
  const match = output.match(/(\d+\.\d+[\.\d]*)/);
  return match ? match[1] : null;
}

const nodeVersion = process.version;
const nodeMajor = parseInt(nodeVersion.replace('v', '').split('.')[0], 10);
const nodeOk = nodeMajor >= 18;

const gitOutput = runCommand('git --version');
const gitVersion = parseVersion(gitOutput);
const gitOk = gitVersion !== null;

const claudeOutput = runCommand('claude --version');
const claudeVersion = parseVersion(claudeOutput);
const claudeOk = claudeVersion !== null;

const result = {
  nodeOk,
  nodeVersion,
  gitOk,
  gitVersion: gitVersion ?? null,
  claudeOk,
  claudeVersion: claudeVersion ?? null,
};

console.log(JSON.stringify(result, null, 2));
process.exit(nodeOk ? 0 : 1);
