import { readFile } from 'fs/promises';
import { existsSync } from 'fs';
import { parse } from 'yaml';
import { HarnessConfig, LockPolicy, DEFAULT_CONFIG, DEFAULT_LOCK_POLICY } from '../types/index.js';

export async function loadConfig(configPath: string): Promise<HarnessConfig> {
  if (!existsSync(configPath)) {
    return { ...DEFAULT_CONFIG };
  }
  const raw = await readFile(configPath, 'utf-8');
  const parsed = parse(raw) as Partial<HarnessConfig>;
  return applyDefaults(parsed);
}

export async function loadLockPolicy(policyPath: string): Promise<LockPolicy> {
  if (!existsSync(policyPath)) {
    return { ...DEFAULT_LOCK_POLICY };
  }
  const raw = await readFile(policyPath, 'utf-8');
  return parse(raw) as LockPolicy;
}

export function configExists(configPath: string): boolean {
  return existsSync(configPath);
}

function applyDefaults(partial: Partial<HarnessConfig>): HarnessConfig {
  return {
    _schema_version: partial._schema_version ?? DEFAULT_CONFIG._schema_version,
    config_package: partial.config_package,
    config_version: partial.config_version,
    teams: partial.teams ?? DEFAULT_CONFIG.teams,
    guardrails: {
      max_files_changed: partial.guardrails?.max_files_changed ?? DEFAULT_CONFIG.guardrails.max_files_changed,
      max_cost_usd: partial.guardrails?.max_cost_usd ?? DEFAULT_CONFIG.guardrails.max_cost_usd,
      max_execution_minutes: partial.guardrails?.max_execution_minutes ?? DEFAULT_CONFIG.guardrails.max_execution_minutes,
    },
    hooks: partial.hooks ?? DEFAULT_CONFIG.hooks,
    rules: partial.rules ?? DEFAULT_CONFIG.rules,
  };
}
