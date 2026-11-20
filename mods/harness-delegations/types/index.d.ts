export type DelegationState = 'running' | 'asking' | 'done' | 'idle' | 'stalled' | 'exited' | 'gone'

export type Tracked = { handle: string; addedAt: number }

export type Snap = {
  state: DelegationState
  label: string
  hash: string
  changedAt: number
  checkedAt: number
  lastLines: string[]
  pr?: string
  worktree?: string
}

declare module 'claude-code' {
  interface PluginState {
    'harness-delegations': {
      tracked: Shaped<Tracked[]>
      snaps: Shaped<Record<string, Snap>>
      now: number
    }
  }
}
