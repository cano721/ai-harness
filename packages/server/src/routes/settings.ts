import { Router } from 'express';
import { readFile, writeFile, access } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';
import { execSync } from 'child_process';
import type { AgentSettings, ApiResponse } from '@ddalkak/shared';

export const settingsRouter = Router();

async function fileExists(path: string): Promise<boolean> {
  try { await access(path); return true; } catch { return false; }
}

async function readJson(path: string): Promise<Record<string, unknown> | null> {
  try { return JSON.parse(await readFile(path, 'utf-8')); } catch { return null; }
}

async function writeJson(path: string, data: unknown): Promise<void> {
  await writeFile(path, JSON.stringify(data, null, 2) + '\n', 'utf-8');
}

function getCliVersion(cmd: string): string | undefined {
  try { return execSync(`${cmd} --version`, { encoding: 'utf-8', timeout: 5000 }).trim(); } catch { return undefined; }
}

async function readAllJsonInDir(dir: string): Promise<Record<string, any>[]> {
  const { readdir } = await import('fs/promises');
  const results: Record<string, any>[] = [];
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        const settingsPath = join(dir, entry.name, 'settings.json');
        const data = await readJson(settingsPath);
        if (data) results.push({ _projectDir: entry.name, ...data });
      }
    }
  } catch {}
  return results;
}

function getClaudeConfigPath() { return join(homedir(), '.claude', 'settings.json'); }
function getCodexConfigPath() { return join(homedir(), '.codex', 'config.json'); }
function getCursorConfigPath() { return join(homedir(), '.cursor', 'settings.json'); }

function getConfigPath(type: string): string | null {
  switch (type) {
    case 'claude_local': return getClaudeConfigPath();
    case 'codex_local': return getCodexConfigPath();
    case 'cursor_local': return getCursorConfigPath();
    default: return null;
  }
}

async function detectAgent(type: string): Promise<AgentSettings> {
  const configPath = getConfigPath(type);
  if (!configPath) return { type: type as any, installed: false, settings: {} };

  const installed = await fileExists(configPath);
  const settings = installed ? (await readJson(configPath)) ?? {} : {};
  const s = settings as any;

  // Extract hooks detail
  const hooksRaw = s?.hooks ?? {};
  const hooks = Object.entries(hooksRaw).flatMap(([event, handlers]: [string, any]) => {
    if (Array.isArray(handlers)) {
      return handlers.map((h: any) => typeof h === 'string' ? h : h.command ?? '');
    }
    return [];
  }).filter(Boolean);

  // Extract MCP servers from global settings only
  const mcpServers = s?.mcpServers ? Object.keys(s.mcpServers) : [];

  const cliCmd = type === 'claude_local' ? 'claude' : type === 'codex_local' ? 'codex' : undefined;

  return {
    type: type as any,
    installed,
    version: cliCmd ? getCliVersion(cliCmd) : undefined,
    configPath: installed ? configPath : undefined,
    settings,
    hooks,
    mcpServers,
  };
}

// --- GET all agent settings ---
settingsRouter.get('/', async (_req, res) => {
  const [claude, codex, cursor] = await Promise.all([
    detectAgent('claude_local'),
    detectAgent('codex_local'),
    detectAgent('cursor_local'),
  ]);
  res.json({ ok: true, data: [claude, codex, cursor] } satisfies ApiResponse);
});

// --- GET MCP server detail ---
settingsRouter.get('/:type/mcp/:serverName', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  const settings = await readJson(configPath);
  const mcpServers = (settings as any)?.mcpServers ?? {};
  const server = mcpServers[req.params.serverName];
  if (!server) { res.status(404).json({ ok: false, error: `MCP server not found: ${req.params.serverName}` }); return; }
  res.json({ ok: true, data: { name: req.params.serverName, ...server } });
});

// --- GET hooks detail ---
settingsRouter.get('/:type/hooks', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  const settings = await readJson(configPath);
  const hooks = (settings as any)?.hooks ?? {};
  res.json({ ok: true, data: hooks });
});

// --- GET plugins detail ---
settingsRouter.get('/:type/plugins', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  const settings = await readJson(configPath);
  const plugins = (settings as any)?.enabledPlugins ?? {};
  const marketplaces = (settings as any)?.extraKnownMarketplaces ?? {};
  res.json({ ok: true, data: { plugins, marketplaces } });
});

// --- PATCH update a setting key ---
settingsRouter.patch('/:type/config', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) ?? {};
  const { key, value } = req.body;

  if (!key) { res.status(400).json({ ok: false, error: 'key is required' }); return; }

  // Set nested key (supports dot notation: "permissions.defaultMode")
  const keys = key.split('.');
  let target: any = settings;
  for (let i = 0; i < keys.length - 1; i++) {
    if (target[keys[i]] === undefined) target[keys[i]] = {};
    target = target[keys[i]];
  }
  target[keys[keys.length - 1]] = value;

  await writeJson(configPath, settings);
  res.json({ ok: true, data: settings });
});

// --- POST add MCP server ---
settingsRouter.post('/:type/mcp', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  const { name, command, args, env } = req.body;

  if (!name || !command) { res.status(400).json({ ok: false, error: 'name and command are required' }); return; }

  if (!settings.mcpServers) settings.mcpServers = {};
  settings.mcpServers[name] = { command, args: args ?? [], ...(env ? { env } : {}) };

  await writeJson(configPath, settings);
  res.json({ ok: true, data: settings.mcpServers[name] });
});

// --- POST test ALL MCP servers ---
settingsRouter.post('/:type/mcp-test-all', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  const servers = settings.mcpServers ?? {};
  const results: Record<string, { status: string; error?: string }> = {};

  const { spawn } = await import('child_process');

  await Promise.all(Object.entries(servers).map(async ([name, server]: [string, any]) => {
    try {
      const result = await new Promise<{ status: string; error?: string }>((resolve) => {
        const mergedEnv = { ...process.env, ...(server.env ?? {}) };
        const child = spawn(server.command, server.args ?? [], { env: mergedEnv, stdio: ['pipe', 'pipe', 'pipe'], shell: false });
        let stderr = '';
        child.stderr?.on('data', (chunk: Buffer) => { stderr += chunk.toString(); });
        const timer = setTimeout(() => { child.kill('SIGTERM'); resolve({ status: 'reachable' }); }, 5000);
        child.on('error', (err) => { clearTimeout(timer); resolve({ status: 'unreachable', error: err.message }); });
        child.on('close', (code) => { clearTimeout(timer); resolve(code === 0 || code === null ? { status: 'reachable' } : { status: 'unreachable', error: stderr.trim() || `Exit code ${code}` }); });
      });
      results[name] = result;
    } catch (err: any) {
      results[name] = { status: 'unreachable', error: err.message };
    }
  }));

  res.json({ ok: true, data: results });
});

// --- POST test MCP server connectivity ---
settingsRouter.post('/:type/mcp/:serverName/test', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  const server = settings.mcpServers?.[req.params.serverName];
  if (!server) { res.status(404).json({ ok: false, error: `MCP server not found: ${req.params.serverName}` }); return; }

  const { spawn } = await import('child_process');

  try {
    const result = await new Promise<{ status: string; error?: string }>((resolve) => {
      const mergedEnv = { ...process.env, ...(server.env ?? {}) };
      const child = spawn(server.command, server.args ?? [], {
        env: mergedEnv,
        stdio: ['pipe', 'pipe', 'pipe'],
        shell: false,
      });

      let stderr = '';
      child.stderr?.on('data', (chunk: Buffer) => { stderr += chunk.toString(); });

      // Give the process 5 seconds to start
      const timer = setTimeout(() => {
        child.kill('SIGTERM');
        resolve({ status: 'reachable' });
      }, 5000);

      child.on('error', (err) => {
        clearTimeout(timer);
        resolve({ status: 'unreachable', error: err.message });
      });

      child.on('close', (code) => {
        clearTimeout(timer);
        // exit code 0 or process was killed by us = reachable
        if (code === 0 || code === null) {
          resolve({ status: 'reachable' });
        } else {
          resolve({ status: 'unreachable', error: stderr.trim() || `Exit code ${code}` });
        }
      });
    });

    res.json({ ok: true, data: result });
  } catch (err: any) {
    res.json({ ok: true, data: { status: 'unreachable', error: err.message } });
  }
});

// --- DELETE MCP server ---
settingsRouter.delete('/:type/mcp/:serverName', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  if (settings.mcpServers?.[req.params.serverName]) {
    delete settings.mcpServers[req.params.serverName];
    await writeJson(configPath, settings);
  }
  res.json({ ok: true });
});

// --- PATCH toggle plugin ---
settingsRouter.patch('/:type/plugins/:pluginId', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  const { enabled } = req.body;

  if (!settings.enabledPlugins) settings.enabledPlugins = {};
  settings.enabledPlugins[req.params.pluginId] = enabled;

  await writeJson(configPath, settings);
  res.json({ ok: true, data: { pluginId: req.params.pluginId, enabled } });
});

// --- PATCH update permission allow list ---
settingsRouter.patch('/:type/permissions', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  const { defaultMode, allow } = req.body;

  if (!settings.permissions) settings.permissions = {};
  if (defaultMode !== undefined) settings.permissions.defaultMode = defaultMode;
  if (allow !== undefined) settings.permissions.allow = allow;

  await writeJson(configPath, settings);
  res.json({ ok: true, data: settings.permissions });
});

// --- GET CLAUDE.md ---
settingsRouter.get('/:type/claudemd', async (req, res) => {
  const home = homedir();
  let mdPath: string;
  switch (req.params.type) {
    case 'claude_local': mdPath = join(home, '.claude', 'CLAUDE.md'); break;
    default: res.status(404).json({ ok: false, error: 'CLAUDE.md not supported for this agent type' }); return;
  }

  try {
    const content = await readFile(mdPath, 'utf-8');
    res.json({ ok: true, data: { path: mdPath, content } });
  } catch {
    res.json({ ok: true, data: { path: mdPath, content: '' } });
  }
});

// --- PUT CLAUDE.md ---
settingsRouter.put('/:type/claudemd', async (req, res) => {
  const home = homedir();
  let mdPath: string;
  switch (req.params.type) {
    case 'claude_local': mdPath = join(home, '.claude', 'CLAUDE.md'); break;
    default: res.status(404).json({ ok: false, error: 'CLAUDE.md not supported for this agent type' }); return;
  }

  const { content } = req.body;
  if (content === undefined) { res.status(400).json({ ok: false, error: 'content is required' }); return; }

  await writeFile(mdPath, content, 'utf-8');
  res.json({ ok: true, data: { path: mdPath, content } });
});

// --- DELETE env variable ---
settingsRouter.delete('/:type/env/:key', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: 'Unknown agent type' }); return; }
  if (!(await fileExists(configPath))) { res.status(404).json({ ok: false, error: 'Config file not found' }); return; }

  const settings = (await readJson(configPath)) as any ?? {};
  if (settings.env?.[req.params.key] !== undefined) {
    delete settings.env[req.params.key];
    await writeJson(configPath, settings);
  }
  res.json({ ok: true });
});

// --- GET specific agent settings (must be last — /:type is a catch-all) ---
settingsRouter.get('/:type', async (req, res) => {
  const configPath = getConfigPath(req.params.type);
  if (!configPath) { res.status(404).json({ ok: false, error: `Unknown agent type: ${req.params.type}` }); return; }
  res.json({ ok: true, data: await detectAgent(req.params.type) });
});
