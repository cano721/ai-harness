import type { LockPolicy, ValidationResult, HarnessConfig } from '../types/index.js';

export function validateSetting(
  key: string,
  value: unknown,
  policy: LockPolicy,
): ValidationResult {
  if (isLocked(key, policy)) {
    return {
      key,
      allowed: false,
      reason: `'${key}'은(는) 잠금(locked) 설정입니다. 변경할 수 없습니다.`,
      level: 'locked',
    };
  }

  const bounded = getBoundedRule(key, policy);
  if (bounded) {
    const numValue = Number(value);
    if (isNaN(numValue)) {
      return {
        key,
        allowed: false,
        reason: `'${key}'은(는) 숫자여야 합니다.`,
        level: 'bounded',
      };
    }
    if (bounded.min !== undefined && numValue < bounded.min) {
      return {
        key,
        allowed: false,
        reason: `'${key}'의 최소값은 ${bounded.min}입니다. (입력값: ${numValue})`,
        level: 'bounded',
      };
    }
    if (bounded.max !== undefined && numValue > bounded.max) {
      return {
        key,
        allowed: false,
        reason: `'${key}'의 최대값은 ${bounded.max}입니다. (입력값: ${numValue})`,
        level: 'bounded',
      };
    }
    return { key, allowed: true, level: 'bounded' };
  }

  return { key, allowed: true, level: 'free' };
}

export function validateConfig(
  config: HarnessConfig,
  policy: LockPolicy,
): ValidationResult[] {
  const violations: ValidationResult[] = [];

  for (const lockedKey of policy.locked) {
    const parts = lockedKey.split('.');
    if (parts[0] === 'hooks' && parts[1]) {
      const hookName = parts[1];
      if (config.hooks[hookName]?.enabled === false) {
        violations.push({
          key: lockedKey,
          allowed: false,
          reason: `'${hookName}' Hook은 잠금(locked) 설정으로 비활성화할 수 없습니다.`,
          level: 'locked',
        });
      }
    }
  }

  for (const [key, rule] of Object.entries(policy.bounded)) {
    const value = getNestedValue(config, key);
    if (value !== undefined) {
      const result = validateSetting(key, value, policy);
      if (!result.allowed) {
        violations.push(result);
      }
    }
  }

  return violations;
}

function isLocked(key: string, policy: LockPolicy): boolean {
  return policy.locked.includes(key);
}

function getBoundedRule(key: string, policy: LockPolicy) {
  return policy.bounded[key];
}

function getNestedValue(obj: object, path: string): unknown {
  const parts = path.split('.');
  let current: unknown = obj;
  for (const part of parts) {
    if (current === null || current === undefined || typeof current !== 'object') {
      return undefined;
    }
    current = (current as Record<string, unknown>)[part];
  }
  return current;
}
