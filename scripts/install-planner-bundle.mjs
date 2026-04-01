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

  if (process.env.CLAUDECODE || process.env.CLAUDE_CONFIG_DIR || process.env.CLAUDE_PROJECT_DIR) {
    return {
      runtime: 'claude',
      detectionReason: 'env:claude',
    };
  }

  if (process.env.CODEX_THREAD_ID) {
    return {
      runtime: 'codex',
      detectionReason: 'env:codex-thread',
    };
  }

  if (process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE) {
    return {
      runtime: 'codex',
      detectionReason: 'env:codex-originator',
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

function isTextFile(filePath) {
  return TEXT_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

function bufferEquals(a, b) {
  return a.length === b.length && a.equals(b);
}

function shouldSkipEntryName(name) {
  return name === '.DS_Store' || name === '__pycache__';
}

function walkFiles(rootDir, currentDir = rootDir) {
  if (!fs.existsSync(currentDir)) {
    return [];
  }

  const entries = fs.readdirSync(currentDir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    if (shouldSkipEntryName(entry.name)) {
      continue;
    }

    const absolutePath = path.join(currentDir, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(rootDir, absolutePath));
      continue;
    }

    if (entry.isFile()) {
      files.push(path.relative(rootDir, absolutePath));
    }
  }

  return files.sort();
}

function countTopLevelDirectories(relativePaths) {
  const entries = new Set();
  for (const relativePath of relativePaths) {
    const topLevelEntry = relativePath.split(path.sep)[0];
    if (topLevelEntry) {
      entries.add(topLevelEntry);
    }
  }
  return entries.size;
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

function writeAsset(asset, options) {
  const sourceMode = fs.statSync(asset.srcPath).mode;
  const source = fs.readFileSync(asset.srcPath);

  if (fs.existsSync(asset.destPath)) {
    const current = fs.readFileSync(asset.destPath);
    const isSame = isTextFile(asset.srcPath)
      ? current.toString('utf-8') === source.toString('utf-8')
      : bufferEquals(current, source);

    if (isSame) {
      options.summary.skipped += 1;
      return;
    }

    ensureBackup(asset.destPath, options.targetRootAbs, options.backupRoot, options.dryRun);
    options.summary.updated += 1;
  } else {
    options.summary.created += 1;
  }

  if (!options.dryRun) {
    ensureDir(path.dirname(asset.destPath), false);
    fs.copyFileSync(asset.srcPath, asset.destPath);
    fs.chmodSync(asset.destPath, sourceMode);
  }
}

function resolveBundleConfig(runtime, bundleRoot, targetRootAbs) {
  if (runtime === 'codex') {
    return {
      runtime,
      displayName: 'Codex',
      bundleRoot,
      targetRootAbs,
      contextFilename: 'AGENTS.md',
      agentsSourceDir: path.join(bundleRoot, 'agents'),
      skillsSourceDir: path.join(bundleRoot, 'skills'),
      templatesSourceDir: path.join(bundleRoot, 'planner-templates'),
      contextTarget: path.join(targetRootAbs, 'AGENTS.md'),
      agentsTargetDir: path.join(targetRootAbs, 'agents'),
      skillsTargetDir: path.join(targetRootAbs, 'skills'),
      templatesTargetDir: path.join(targetRootAbs, 'planner-templates'),
      agentExtension: '.toml',
      agentFormat: 'toml',
    };
  }

  if (runtime === 'claude') {
    return {
      runtime,
      displayName: 'Claude Code',
      bundleRoot,
      targetRootAbs,
      contextFilename: 'CLAUDE.md',
      agentsSourceDir: path.join(bundleRoot, 'agents'),
      skillsSourceDir: path.join(bundleRoot, 'skills'),
      templatesSourceDir: path.join(bundleRoot, 'planner-templates'),
      contextTarget: path.join(targetRootAbs, 'CLAUDE.md'),
      agentsTargetDir: path.join(targetRootAbs, 'agents'),
      skillsTargetDir: path.join(targetRootAbs, 'plugins', 'marketplaces', 'ai-harness', 'skills'),
      templatesTargetDir: path.join(targetRootAbs, 'planner-templates'),
      agentExtension: '.md',
      agentFormat: 'markdown-frontmatter',
    };
  }

  throw new Error(`지원하지 않는 runtime입니다: ${runtime}`);
}

function validateBundle(bundleConfig) {
  const requiredPaths = [
    path.join(bundleConfig.bundleRoot, bundleConfig.contextFilename),
    bundleConfig.agentsSourceDir,
    bundleConfig.skillsSourceDir,
  ];

  for (const requiredPath of requiredPaths) {
    if (!fs.existsSync(requiredPath)) {
      throw new Error(`bundle 자산이 없습니다: ${requiredPath}`);
    }
  }
}

function getPostInstallActions(bundleConfig) {
  if (bundleConfig.runtime !== 'claude') {
    return [];
  }

  return [
    {
      type: 'run-skill',
      skill: 'refresh-planning-subagents',
      target: path.join(bundleConfig.skillsTargetDir, 'refresh-planning-subagents', 'SKILL.md'),
      reason: 'Claude Code에서는 planner agents를 복사한 뒤 native subagent 자산을 한 번 더 정리해야 할 수 있습니다.',
      prompt: '설치된 ~/.claude/agents/*.md 를 기준으로 ai-harness planner subagents를 다시 생성하거나 보정해줘.',
    },
  ];
}

function buildInstallPlan(bundleRoot, runtime, targetRootAbs) {
  const bundleConfig = resolveBundleConfig(runtime, bundleRoot, targetRootAbs);
  validateBundle(bundleConfig);

  const agentFiles = walkFiles(bundleConfig.agentsSourceDir);
  const skillFiles = walkFiles(bundleConfig.skillsSourceDir);
  const templateFiles = walkFiles(bundleConfig.templatesSourceDir);
  const assets = [
    {
      kind: 'context',
      srcPath: path.join(bundleConfig.bundleRoot, bundleConfig.contextFilename),
      destPath: bundleConfig.contextTarget,
      relativeTargetPath: path.basename(bundleConfig.contextTarget),
    },
    ...agentFiles.map((relativePath) => ({
      kind: 'agent',
      srcPath: path.join(bundleConfig.agentsSourceDir, relativePath),
      destPath: path.join(bundleConfig.agentsTargetDir, relativePath),
      relativeTargetPath: path.join('agents', relativePath),
    })),
    ...skillFiles.map((relativePath) => ({
      kind: 'skill',
      srcPath: path.join(bundleConfig.skillsSourceDir, relativePath),
      destPath: path.join(bundleConfig.skillsTargetDir, relativePath),
      relativeTargetPath: path.join('skills', relativePath),
    })),
    ...templateFiles.map((relativePath) => ({
      kind: 'template',
      srcPath: path.join(bundleConfig.templatesSourceDir, relativePath),
      destPath: path.join(bundleConfig.templatesTargetDir, relativePath),
      relativeTargetPath: path.join('planner-templates', relativePath),
    })),
  ];

  return {
    bundleConfig,
    assets,
    sourceAgentCount: countTopLevelDirectories(agentFiles),
    sourceSkillCount: countTopLevelDirectories(skillFiles),
    sourceTemplateCount: templateFiles.length,
  };
}

function hasAtlassianCredentials() {
  const credentialsPath = path.join(os.homedir(), '.claude', 'credentials.md');
  if (!fs.existsSync(credentialsPath)) {
    return false;
  }
  const content = fs.readFileSync(credentialsPath, 'utf-8');
  return /Atlassian/i.test(content);
}

function inspect(bundleRoot, runtime, targetRootAbs, detectionReason) {
  const plan = buildInstallPlan(bundleRoot, runtime, targetRootAbs);
  const { bundleConfig } = plan;

  return {
    runtime,
    detectionReason,
    displayName: bundleConfig.displayName,
    bundleRoot,
    targetRoot: targetRootAbs,
    contextTarget: bundleConfig.contextTarget,
    agentsTargetDir: bundleConfig.agentsTargetDir,
    skillsTargetDir: bundleConfig.skillsTargetDir,
    agentFormat: bundleConfig.agentFormat,
    sourceSkillCount: plan.sourceSkillCount,
    sourceAgentCount: plan.sourceAgentCount,
    sourceTemplateCount: plan.sourceTemplateCount,
    installedSkillCount: listDirectories(bundleConfig.skillsTargetDir).length,
    installedAgentCount: listFiles(bundleConfig.agentsTargetDir, bundleConfig.agentExtension).length,
    installedTemplateCount: listFiles(bundleConfig.templatesTargetDir).length,
    atlassianReady: hasAtlassianCredentials(),
    postInstallActions: getPostInstallActions(bundleConfig),
  };
}

function install(bundleRoot, runtime, targetRootAbs, detectionReason, dryRun) {
  const plan = buildInstallPlan(bundleRoot, runtime, targetRootAbs);
  const timestamp = new Date().toISOString().replaceAll(':', '').replaceAll('.', '');
  const summary = { created: 0, updated: 0, skipped: 0 };
  const backupRoot = path.join(targetRootAbs, 'backups', `planner-bundle-${timestamp}`);

  ensureDir(targetRootAbs, dryRun);

  for (const asset of plan.assets) {
    writeAsset(asset, {
      backupRoot,
      dryRun,
      summary,
      targetRootAbs,
    });
  }

  return {
    ...inspect(bundleRoot, runtime, targetRootAbs, detectionReason),
    dryRun,
    summary,
    backupRoot: summary.updated > 0 ? backupRoot : null,
  };
}

function usage() {
  console.error('사용법:');
  console.error('  node scripts/install-planner-bundle.mjs inspect [--runtime auto|codex|claude] [--bundle-root <path>] [--target-root <path>|--target-dir <path>]');
  console.error('  node scripts/install-planner-bundle.mjs install [--runtime auto|codex|claude] [--bundle-root <path>] [--target-root <path>|--target-dir <path>] [--dry-run]');
  process.exit(1);
}

export {
  buildInstallPlan,
  detectRuntime,
  isTextFile,
  parseArgs,
  resolveBundleConfig,
};

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
  const detectedRuntime = detectRuntime(args.runtime || 'auto', scriptDir);
  const runtime = detectedRuntime.runtime;
  const defaultBundleRoot = path.resolve(scriptDir, '..', 'teams', 'planning', `bundle-${runtime}`);
  const bundleRoot = args['bundle-root']
    ? path.resolve(args['bundle-root'])
    : defaultBundleRoot;
  const targetRootValue = args['target-root'] || args['target-dir'];
  const targetRootAbs = targetRootValue
    ? path.resolve(targetRootValue)
    : path.join(os.homedir(), runtime === 'codex' ? '.codex' : '.claude');

  try {
    if (command === 'inspect') {
      console.log(JSON.stringify(
        inspect(bundleRoot, runtime, targetRootAbs, detectedRuntime.detectionReason),
        null,
        2,
      ));
      process.exit(0);
    }

    if (command === 'install') {
      console.log(JSON.stringify(
        install(
          bundleRoot,
          runtime,
          targetRootAbs,
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
}
