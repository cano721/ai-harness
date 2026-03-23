import type { HarnessConfig } from '../types/index.js';

export function mergeConfigs(
  global: Partial<HarnessConfig>,
  teams: Partial<HarnessConfig>[],
  project: Partial<HarnessConfig>,
): HarnessConfig {
  let result = deepClone(global) as HarnessConfig;

  for (const team of teams) {
    result = mergeTwo(result, team);
  }

  result = mergeTwo(result, project);

  return result;
}

function mergeTwo(base: HarnessConfig | Partial<HarnessConfig>, override: Partial<HarnessConfig>): HarnessConfig {
  const result: HarnessConfig = {
    _schema_version: override._schema_version ?? (base as HarnessConfig)._schema_version ?? 1,
    config_package: override.config_package ?? base.config_package,
    config_version: override.config_version ?? base.config_version,
    teams: mergeArrays(base.teams, override.teams),
    guardrails: {
      max_files_changed: override.guardrails?.max_files_changed ?? base.guardrails?.max_files_changed ?? 20,
      max_cost_usd: override.guardrails?.max_cost_usd ?? base.guardrails?.max_cost_usd ?? 5.0,
      max_execution_minutes: override.guardrails?.max_execution_minutes ?? base.guardrails?.max_execution_minutes ?? 30,
    },
    hooks: { ...base.hooks, ...override.hooks },
    rules: { ...base.rules, ...override.rules },
  };

  return result;
}

function mergeArrays(base?: string[], override?: string[]): string[] {
  if (!base && !override) return [];
  if (!base) return [...(override ?? [])];
  if (!override) return [...base];
  return [...new Set([...base, ...override])];
}

function deepClone<T>(obj: T): T {
  return structuredClone(obj);
}
