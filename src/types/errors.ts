export enum HarnessErrorCode {
  CONFIG_LOAD_FAILED = 'CONFIG_LOAD_FAILED',
  CONFIG_PARSE_FAILED = 'CONFIG_PARSE_FAILED',
  HOOK_NOT_FOUND = 'HOOK_NOT_FOUND',
  HOOK_EXECUTION_FAILED = 'HOOK_EXECUTION_FAILED',
  HOOK_TIMEOUT = 'HOOK_TIMEOUT',
  LOCK_POLICY_VIOLATION = 'LOCK_POLICY_VIOLATION',
  SETTINGS_WRITE_FAILED = 'SETTINGS_WRITE_FAILED',
  SNAPSHOT_FAILED = 'SNAPSHOT_FAILED',
  ADAPTER_DETECT_FAILED = 'ADAPTER_DETECT_FAILED',
}

export class HarnessError extends Error {
  constructor(
    public readonly code: HarnessErrorCode,
    message: string,
    public readonly suggestion?: string,
  ) {
    super(message);
    this.name = 'HarnessError';
  }
}
