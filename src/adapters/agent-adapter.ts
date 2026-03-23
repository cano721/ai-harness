export interface AgentAdapter {
  readonly name: string;
  readonly capabilities: AgentCapabilities;
  detect(): Promise<DetectResult>;
  injectContext(context: HarnessContext): Promise<void>;
  registerHooks?(hooks: HarnessHook[]): Promise<void>;
  cleanup(): Promise<void>;
}

export interface AgentCapabilities {
  contextInjection: true;
  hooks: 'full' | 'partial' | 'none';
  mcp: 'native' | 'partial' | 'none';
  settingsFile: boolean;
  hierarchicalContext: boolean;
}

export interface DetectResult {
  installed: boolean;
  version?: string;
  configDir?: string;
}

export interface HarnessContext {
  global: string;
  teams: string[];
  rules: Record<string, unknown>;
}

export interface HarnessHook {
  event: string;
  matcher: string;
  command: string;
}
