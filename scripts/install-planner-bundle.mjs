#!/usr/bin/env node
import fs from 'fs';
import os from 'os';
import path from 'path';
import url from 'url';

const TEXT_EXTENSIONS = new Set([
  '.json',
  '.md',
  '.mdx',
  '.txt',
  '.toml',
  '.yaml',
  '.yml',
]);

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      args._.push(arg);
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      args[key] = true;
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function ensureDir(dirPath, dryRun) {
  if (dryRun || fs.existsSync(dirPath)) {
    return;
  }
  fs.mkdirSync(dirPath, { recursive: true });
}

function listDirectories(dirPath) {
  if (!fs.existsSync(dirPath)) {
    return [];
  }
  return fs.readdirSync(dirPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
    .map((entry) => entry.name)
    .sort();
}

function listFiles(dirPath, extension) {
  if (!fs.existsSync(dirPath)) {
    return [];
  }
  return fs.readdirSync(dirPath, { withFileTypes: true })
    .filter((entry) => entry.isFile() && (!extension || entry.name.endsWith(extension)))
    .map((entry) => entry.name)
    .sort();
}

function detectRuntime(explicitRuntime, scriptPath) {
  if (explicitRuntime && explicitRuntime !== 'auto') {
    return {
      runtime: explicitRuntime,
      detectionReason: `explicit:${explicitRuntime}`,
    };
  }

  if (process.env.CODEX_THREAD_ID || process.env.CODEX_SHELL || process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE) {
    return {
      runtime: 'codex',
      detectionReason: 'env:codex',
    };
  }

  if (process.env.CLAUDECODE || process.env.CLAUDE_CONFIG_DIR || process.env.CLAUDE_PROJECT_DIR) {
    return {
      runtime: 'claude',
      detectionReason: 'env:claude',
    };
  }

  if (scriptPath.includes(`${path.sep}.claude${path.sep}`)) {
    return {
      runtime: 'claude',
      detectionReason: 'path:.claude',
    };
  }

  if (scriptPath.includes(`${path.sep}.codex${path.sep}`)) {
    return {
      runtime: 'codex',
      detectionReason: 'path:.codex',
    };
  }

  const home = os.homedir();
  const codexExists = fs.existsSync(path.join(home, '.codex'));
  const claudeExists = fs.existsSync(path.join(home, '.claude'));

  if (claudeExists && !codexExists) {
    return {
      runtime: 'claude',
      detectionReason: 'home-only:claude',
    };
  }

  if (codexExists && !claudeExists) {
    return {
      runtime: 'codex',
      detectionReason: 'home-only:codex',
    };
  }

  return {
    runtime: 'claude',
    detectionReason: claudeExists ? 'home-both:claude' : 'default:claude',
  };
}

function loadRuntimeConfig(bundleRoot, runtime) {
  const configPath = path.join(bundleRoot, 'runtimes', `${runtime}.json`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`런타임 설정이 없습니다: ${configPath}`);
  }
  return JSON.parse(fs.readFileSync(configPath, 'utf-8'));
}

function interpolateReplacement(value, vars) {
  return value
    .replaceAll('{{TARGET_ROOT_ABS}}', vars.targetRootAbs)
    .replaceAll('{{TARGET_ROOT_TILDE}}', vars.targetRootTilde);
}

function transformText(content, replacements, vars) {
  let result = content;
  for (const replacement of replacements) {
    const from = replacement.from;
    const to = interpolateReplacement(replacement.to, vars);
    result = result.split(from).join(to);
  }
  return result;
}

function isTextFile(filePath) {
  return TEXT_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

function bufferEquals(a, b) {
  return a.length === b.length && a.equals(b);
}

function ensureBackup(originalPath, targetRoot, backupRoot, dryRun) {
  if (!fs.existsSync(originalPath) || dryRun) {
    return;
  }
  const relativePath = path.relative(targetRoot, originalPath);
  const backupPath = path.join(backupRoot, relativePath);
  if (fs.existsSync(backupPath)) {
    return;
  }
  ensureDir(path.dirname(backupPath), false);
  fs.copyFileSync(originalPath, backupPath);
}

function writeTextFile(srcPath, destPath, options) {
  const sourceMode = fs.statSync(srcPath).mode;
  const source = fs.readFileSync(srcPath, 'utf-8');
  const transformed = transformText(source, options.replacements, options.vars);

  if (fs.existsSync(destPath)) {
    const current = fs.readFileSync(destPath, 'utf-8');
    if (current === transformed) {
      options.summary.skipped += 1;
      return;
    }
    ensureBackup(destPath, options.targetRootAbs, options.backupRoot, options.dryRun);
    options.summary.updated += 1;
  } else {
    options.summary.created += 1;
  }

  if (!options.dryRun) {
    ensureDir(path.dirname(destPath), false);
    fs.writeFileSync(destPath, transformed, 'utf-8');
    fs.chmodSync(destPath, sourceMode);
  }
}

function writeBinaryFile(srcPath, destPath, options) {
  const sourceMode = fs.statSync(srcPath).mode;
  const source = fs.readFileSync(srcPath);

  if (fs.existsSync(destPath)) {
    const current = fs.readFileSync(destPath);
    if (bufferEquals(current, source)) {
      options.summary.skipped += 1;
      return;
    }
    ensureBackup(destPath, options.targetRootAbs, options.backupRoot, options.dryRun);
    options.summary.updated += 1;
  } else {
    options.summary.created += 1;
  }

  if (!options.dryRun) {
    ensureDir(path.dirname(destPath), false);
    fs.copyFileSync(srcPath, destPath);
    fs.chmodSync(destPath, sourceMode);
  }
}

function copyDirectory(srcDir, destDir, options) {
  const entries = fs.readdirSync(srcDir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name === '.DS_Store' || entry.name === '__pycache__') {
      continue;
    }
    const srcPath = path.join(srcDir, entry.name);
    const destPath = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      copyDirectory(srcPath, destPath, options);
      continue;
    }
    if (entry.isFile()) {
      if (isTextFile(srcPath)) {
        writeTextFile(srcPath, destPath, options);
      } else {
        writeBinaryFile(srcPath, destPath, options);
      }
    }
  }
}

function hasAtlassianCredentials() {
  const credentialsPath = path.join(os.homedir(), '.claude', 'credentials.md');
  if (!fs.existsSync(credentialsPath)) {
    return false;
  }
  const content = fs.readFileSync(credentialsPath, 'utf-8');
  return /Atlassian/i.test(content);
}

function inspect(bundleRoot, runtimeConfig, targetRootAbs, runtime, detectionReason) {
  const commonRoot = path.join(bundleRoot, 'common');
  const templatesRoot = path.join(bundleRoot, 'templates');
  const skills = listDirectories(path.join(commonRoot, 'skills'));
  const agents = listFiles(path.join(commonRoot, 'agents'), '.toml');
  const templates = listFiles(templatesRoot);
  const targetSkills = listDirectories(path.join(targetRootAbs, runtimeConfig.skillsTargetDir));
  const targetAgents = listFiles(path.join(targetRootAbs, runtimeConfig.agentsTargetDir), '.toml');
  const targetTemplates = runtimeConfig.templatesTargetDir
    ? listFiles(path.join(targetRootAbs, runtimeConfig.templatesTargetDir))
    : [];

  return {
    runtime,
    detectionReason,
    displayName: runtimeConfig.displayName,
    bundleRoot,
    targetRoot: targetRootAbs,
    contextTarget: path.join(targetRootAbs, runtimeConfig.contextTarget),
    sourceSkillCount: skills.length,
    sourceAgentCount: agents.length,
    sourceTemplateCount: templates.length,
    installedSkillCount: targetSkills.length,
    installedAgentCount: targetAgents.length,
    installedTemplateCount: targetTemplates.length,
    atlassianReady: hasAtlassianCredentials(),
  };
}

function install(bundleRoot, runtimeConfig, targetRootAbs, runtime, detectionReason, dryRun) {
  const timestamp = new Date().toISOString().replaceAll(':', '').replaceAll('.', '');
  const commonRoot = path.join(bundleRoot, 'common');
  const vars = {
    targetRootAbs,
    targetRootTilde: path.join('~', runtimeConfig.homeDirName),
  };
  const summary = { created: 0, updated: 0, skipped: 0 };
  const backupRoot = path.join(targetRootAbs, 'backups', `planner-bundle-${timestamp}`);

  const options = {
    backupRoot,
    dryRun,
    replacements: runtimeConfig.replacements || [],
    summary,
    targetRootAbs,
    vars,
  };

  ensureDir(targetRootAbs, dryRun);

  writeTextFile(
    path.join(commonRoot, runtimeConfig.contextSource),
    path.join(targetRootAbs, runtimeConfig.contextTarget),
    options,
  );

  copyDirectory(
    path.join(commonRoot, 'agents'),
    path.join(targetRootAbs, runtimeConfig.agentsTargetDir),
    options,
  );

  copyDirectory(
    path.join(commonRoot, 'skills'),
    path.join(targetRootAbs, runtimeConfig.skillsTargetDir),
    options,
  );

  if (runtimeConfig.templatesTargetDir) {
    copyDirectory(
      path.join(bundleRoot, 'templates'),
      path.join(targetRootAbs, runtimeConfig.templatesTargetDir),
      options,
    );
  }

  const inspection = inspect(bundleRoot, runtimeConfig, targetRootAbs, runtime, detectionReason);
  return {
    ...inspection,
    dryRun,
    summary,
    backupRoot: summary.updated > 0 ? backupRoot : null,
  };
}

export { detectRuntime, transformText, parseArgs, isTextFile };

function usage() {
  console.error('사용법:');
  console.error('  node scripts/install-planner-bundle.mjs inspect [--runtime auto|codex|claude] [--bundle-root <path>] [--target-root <path>|--target-dir <path>]');
  console.error('  node scripts/install-planner-bundle.mjs install [--runtime auto|codex|claude] [--bundle-root <path>] [--target-root <path>|--target-dir <path>] [--dry-run]');
  process.exit(1);
}

const isCLI = process.argv[1] && url.fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (!isCLI) {
  // imported as module — skip CLI execution
} else {

const args = parseArgs(process.argv.slice(2));
const command = args._[0];

if (!command) {
  usage();
}

const scriptDir = path.dirname(url.fileURLToPath(import.meta.url));
const bundleRoot = args['bundle-root']
  ? path.resolve(args['bundle-root'])
  : path.resolve(scriptDir, '..', 'teams', 'planning', 'bundle');
const detectedRuntime = detectRuntime(args.runtime || 'auto', scriptDir);
const runtime = detectedRuntime.runtime;
const runtimeConfig = loadRuntimeConfig(bundleRoot, runtime);
const targetRootValue = args['target-root'] || args['target-dir'];
const targetRootAbs = targetRootValue
  ? path.resolve(targetRootValue)
  : path.join(os.homedir(), runtimeConfig.homeDirName);

try {
  if (command === 'inspect') {
    console.log(JSON.stringify(
      inspect(bundleRoot, runtimeConfig, targetRootAbs, runtime, detectedRuntime.detectionReason),
      null,
      2,
    ));
    process.exit(0);
  }

  if (command === 'install') {
    console.log(JSON.stringify(
      install(
        bundleRoot,
        runtimeConfig,
        targetRootAbs,
        runtime,
        detectedRuntime.detectionReason,
        Boolean(args['dry-run']),
      ),
      null,
      2,
    ));
    process.exit(0);
  }

  usage();
} catch (error) {
  console.error(`오류: ${error.message}`);
  process.exit(1);
}

} // end isCLI
