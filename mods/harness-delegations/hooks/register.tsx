import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import type { DelegationState, Snap, Tracked } from '../types'

type Engine = Parameters<Hook<'session.start'>>[0]

const PANE = 'harness-delegations'
const COMMAND = 'harness-delegations'
const POLL_MS = 15_000
const ASK_IDLE_MS = 20_000
const STALL_MS = 10 * 60_000
const HIDE_ENDED_MS = 10 * 60_000

const tracked = atom({ plugin: 'harness-delegations', key: 'tracked' } as const, [], { shape: 'tracked-1' })
const snaps = atom({ plugin: 'harness-delegations', key: 'snaps' } as const, {}, { shape: 'snaps-1' })
const nowAtom = atom({ plugin: 'harness-delegations', key: 'now' } as const, 0)

const HANDLE = /term_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g
const SPAWN = /orca\s+(terminal\s+(create|split)|agent\s+launch|worktree\s+create)/
const WAIT = /wait-delegation\.sh/

// wait-delegation.sh 와 같은 판정 문구 — 바꾸면 두 곳을 함께 바꾼다.
const ASK = /Enter to (select|confirm)|Esc to cancel|to navigate|trust this folder|Do you want to|Would you like to|Allow (command|this)|Press enter to (confirm|approve)|\(y\/n\)|❯ *(1\.|Yes|No)( |,|$)/i
const ASK_TAIL = /(\?|할까요|될까요|주세요|승인)\s*$/
const BUSY = /esc to interrupt|[0-9]+ shells?( still running)?|still running|monitor/i

const ORDER: Record<DelegationState, number> = { asking: 0, stalled: 1, done: 2, idle: 3, running: 4, exited: 5, gone: 6 }
const ICON: Record<DelegationState, string> = { running: '▶', asking: '?', done: '✓', idle: '⏸', stalled: '⚠', exited: '✕', gone: '✕' }
const WORD: Record<DelegationState, string> = {
  running: '작업 중', asking: '입력 대기', done: '완료', idle: '턴 끝남',  stalled: '정체', exited: '종료', gone: '사라짐',
}
const COLOR: Partial<Record<DelegationState, string>> = { running: 'success', done: 'success', asking: 'warning', stalled: 'error' }

export function handlesFromSpawn(command: string, output: string): string[] {
  const found = new Set<string>()
  if (SPAWN.test(command)) for (const h of output.match(HANDLE) ?? []) found.add(h)
  if (WAIT.test(command)) for (const h of command.match(HANDLE) ?? []) found.add(h)
  return [...found]
}

const PR = /(?:\bPR #|\/pull(?:-requests)?\/)(\d+)/g

// 화면(상태 표시줄 포함)에 보이는 마지막 PR 번호. Claude Code 는 세션이 만든 PR 을 상태 표시줄에 띄운다.
export function prOf(lines: string[]): string | undefined {
  const all = [...lines.join('\n').matchAll(PR)]
  return all.length ? all[all.length - 1]![1] : undefined
}

// 입력창이 잠깐 비는 순간(도구 사이)을 끝남으로 보지 않도록, 화면이 ASK_IDLE_MS 동안 그대로일 때만 멈춘 것으로 본다.
export function classify(lines: string[], status: string, idleMs: number): DelegationState {
  if (status === 'exited') return 'exited'
  const text = lines.filter(l => l.trim() !== '')
  const tail12 = text.slice(-12)
  if (text.slice(-6).some(l => BUSY.test(l))) return idleMs >= STALL_MS ? 'stalled' : 'running'
  if (idleMs < ASK_IDLE_MS) return 'running'
  if (tail12.some(l => ASK.test(l)) || ASK_TAIL.test(contentLines(text).slice(-6).join('\n'))) return 'asking'
  return prOf(text) ? 'done' : 'idle'
}

export function labelOf(t: { title?: string; branch?: string; worktreePath?: string }): string {
  const base = t.worktreePath?.split('/').filter(Boolean).pop()
  const title = t.title?.replace(/^[^\p{L}\p{N}]+/u, '').trim()
  const raw = title || t.branch?.replace(/^refs\/heads\//, '') || base || '세션'
  return raw.length > 20 ? raw.slice(0, 19) + '…' : raw
}

export function ago(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return '방금'
  if (s < 3600) return `${Math.floor(s / 60)}분`
  return `${Math.floor(s / 3600)}시간`
}

// 입력창 아래(상태 표시줄의 경과 시간·비용)는 일이 멈춰도 바뀐다 — 구분선 두 개 중 위쪽 것 위만 본다.
export function contentLines(lines: string[]): string[] {
  const rules = lines.flatMap((l, i) => (/^\s*[─━-]{20,}\s*$/.test(l) ? [i] : []))
  return rules.length >= 2 ? lines.slice(0, rules[rules.length - 2]) : lines
}

function hashOf(s: string): string {
  let h = 5381
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0
  return String(h)
}

function textOf(content: unknown): string {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) return content.map(c => (c && typeof c === 'object' && 'text' in c ? String(c.text) : '')).join('\n')
  return ''
}

// 이 세션 대화 기록에서 예전에 띄운 터미널을 다시 찾는다(재개·mod 재로드 뒤에도 목록이 이어지도록).
export function handlesFromTranscript(jsonl: string): string[] {
  const commands = new Map<string, string>()
  const found = new Set<string>()
  for (const line of jsonl.split('\n')) {
    if (!line.includes('term_') && !line.includes('"Bash"')) continue
    let row: any
    try { row = JSON.parse(line) } catch { continue }
    const content = row?.message?.content
    if (!Array.isArray(content)) continue
    for (const c of content) {
      if (c?.type === 'tool_use' && c.name === 'Bash' && typeof c.input?.command === 'string') {
        commands.set(c.id, c.input.command)
        for (const h of handlesFromSpawn(c.input.command, '')) found.add(h)
      } else if (c?.type === 'tool_result' && commands.has(c.tool_use_id)) {
        for (const h of handlesFromSpawn(commands.get(c.tool_use_id)!, textOf(c.content))) found.add(h)
      }
    }
  }
  return [...found]
}

let polling = false
let ownHandle = ''

async function track($: Engine, handles: string[]) {
  const fresh = handles.filter(h => h !== ownHandle)
  if (fresh.length === 0) return
  const now = await $.clock.now()
  await update($, tracked, list => {
    const have = new Set(list.map(t => t.handle))
    return [...list, ...fresh.filter(h => !have.has(h)).map(handle => ({ handle, addedAt: now }))]
  })
  void poll($)
}

async function orcaJson($: Engine, argv: string[]): Promise<any> {
  const { exitCode, stdout } = await $.process.run(['orca', ...argv, '--json'], { timeoutMs: 10_000 })
  if (exitCode !== 0) return null
  try {
    const out = JSON.parse(stdout)
    return out?.ok ? out.result : null
  } catch { return null }
}

async function poll($: Engine) {
  if (polling) return
  polling = true
  try {
    const list: Tracked[] = await read($, tracked)
    const now = await $.clock.now()
    if (list.length === 0) return
    const live = await orcaJson($, ['terminal', 'list'])
    if (!live) return
    const byHandle = new Map<string, any>((live.terminals ?? []).map((t: any) => [t.handle, t]))
    const prev: Record<string, Snap> = await read($, snaps)
    const next: Record<string, Snap> = {}
    const alerts: { handle: string; snap: Snap }[] = []
    const taken = new Set(list.map(t => t.handle))
    const rebound = new Map<string, string>()
    for (const item of list) {
      let handle = item.handle
      let old = prev[handle]
      let meta = byHandle.get(handle)
      if (!meta) {
        // 탭이 닫히고 같은 worktree 에 세션이 다시 떴으면(Orca 재시작·탭 다시 열기) 그 탭을 이어 추적한다.
        const worktree = old?.worktree ?? (await orcaJson($, ['terminal', 'show', '--terminal', handle]))?.terminal?.worktreePath
        const heir = worktree ? findHeir(live.terminals ?? [], worktree, taken) : undefined
        if (heir) {
          rebound.set(handle, heir.handle)
          taken.add(heir.handle)
          handle = heir.handle
          meta = heir
          old = old ? { ...old, worktree } : old
        }
      }
      if (!meta) {
        next[handle] = old && (old.state === 'gone' || old.state === 'exited' || old.state === 'done')
          ? old
          : { state: old?.pr ? 'done' : 'gone', label: old?.label ?? handle.slice(5, 13), hash: '', changedAt: now, checkedAt: now, lastLines: old?.lastLines ?? [], pr: old?.pr, worktree: old?.worktree }
        if (old && !['gone', 'exited', 'done'].includes(old.state)) alerts.push({ handle, snap: next[handle]! })
        continue
      }
      const screen = await orcaJson($, ['terminal', 'read', '--terminal', handle, '--screen'])
      const lines: string[] = screen?.terminal?.tail ?? old?.lastLines ?? []
      const hash = hashOf(contentLines(lines).join('\n'))
      const changedAt = old && old.hash === hash ? old.changedAt : now
      const pr = prOf(lines) ?? old?.pr
      const seen = classify(lines, screen?.terminal?.status ?? 'unknown', now - changedAt)
      // PR 까지 낸 세션이 닫히면 실패가 아니라 끝난 것이다.
      const state = seen === 'exited' && pr ? 'done' : seen
      const label = labelOf(meta)
      next[handle] = {
        state, label, hash, changedAt, checkedAt: now, pr,
        worktree: meta.worktreePath || old?.worktree,
        lastLines: contentLines(lines).filter(l => l.trim() !== '').slice(-3),
      }
      if (old && old.state !== state && state !== 'running') alerts.push({ handle, snap: next[handle]! })
    }
    if (rebound.size) {
      await update($, tracked, l => l.map(t => (rebound.has(t.handle) ? { ...t, handle: rebound.get(t.handle)! } : t)))
    }
    await update($, snaps, () => next)
    await update($, nowAtom, () => now)
    if (alerts.length) await report($, alerts)
  } catch {
    // orca 가 없거나 막힌 환경 — 줄을 비운 채 두고 보드를 대안으로 남긴다.
  } finally {
    polling = false
  }
}

// 폴더 workspace(worktreePath 없음)는 여러 세션이 한 폴더를 같이 써서 이어받을 탭을 고를 수 없다.
export function findHeir(terminals: any[], worktree: string, taken: Set<string>): any | undefined {
  if (!worktree) return undefined
  return terminals.find(t => t.worktreePath === worktree && t.handle !== ownHandle && !taken.has(t.handle) && !t.orphaned)
}

export function headline(s: Snap): string {
  return `${ICON[s.state]} ${s.label} ${WORD[s.state]}${s.pr ? ` · PR #${s.pr}` : ''}`
}

// 사람에게는 알림, 조율 세션(모델)에게는 메시지로 알린다 — 알림만으로는 모델이 몰라 사용자에게 보고하지 못했다.
async function report($: Engine, alerts: { handle: string; snap: Snap }[]) {
  $.ui.toast(`위임 세션: ${alerts.map(a => headline(a.snap)).join(' · ')}`)
  const body = alerts.map(a => [
    `- ${headline(a.snap)} (${a.handle})`,
    ...a.snap.lastLines.map(l => `    ${l.trim().slice(0, 160)}`),
  ].join('\n')).join('\n')
  try {
    await $.prompt.submit({
      text: `맡긴 세션 상태가 바뀌었다. 확인해서 사용자에게 결과(완료면 PR·CI, 질문이면 내용, 정체·종료면 원인)를 알려라.\n${body}`,
    })
  } catch {}
}

async function jump($: Engine, handle: string, label: string) {
  try {
    const { exitCode } = await $.process.run(['orca', 'terminal', 'switch', '--terminal', handle], { timeoutMs: 10_000 })
    if (exitCode === 0) return
  } catch {}
  $.ui.toast(`${label} 탭으로 이동하지 못함 — /ai-harness:board 에서 확인`)
}

async function rows($: Engine) {
  const list: Tracked[] = await read($, tracked)
  const all: Record<string, Snap> = await read($, snaps)
  const now = (await read($, nowAtom)) || (await $.clock.now())
  return list
    .map(t => ({ handle: t.handle, snap: all[t.handle] }))
    .filter((r): r is { handle: string; snap: Snap } => !!r.snap)
    .sort((a, b) => ORDER[a.snap.state] - ORDER[b.snap.state])
    .map(r => ({ ...r, now }))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if (!e.isInteractive) return started
    ownHandle = (await $.env.get('ORCA_TERMINAL_HANDLE')) ?? ''
    await $.command.register({
      name: COMMAND,
      description: '맡긴 세션 목록을 패널로 보기 (forget <handle>|clear 로 정리)',
      argumentHint: '[clear | forget <handle>]',
      immediate: true,
    })
    try {
      const { transcriptPath } = await $.session.info()
      if (transcriptPath) await track($, handlesFromTranscript(await $.fs.read(transcriptPath)))
    } catch {}
    $.clock.every(POLL_MS, () => poll($))
    void poll($)
    return started
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    const command = (e as { command?: string }).command ?? ''
    if (SPAWN.test(command) || WAIT.test(command)) {
      const r = (ran as { result?: { stdout?: string } }).result
      void track($, handlesFromSpawn(command, r?.stdout ?? '')).catch(() => {})
    }
    return ran
  }).catch(($, e, next) => next(e))

  on('command.run', { command: COMMAND }, async ($, e) => {
    const args = String((e as { args?: string }).args ?? '').trim().split(/\s+/).filter(Boolean)
    if (args[0] === 'clear') {
      const all: Record<string, Snap> = await read($, snaps)
      await update($, tracked, list => list.filter(t => !['exited', 'gone', 'done'].includes(all[t.handle]?.state ?? '')))
      return { text: '끝난 위임 세션을 목록에서 뺐습니다.' }
    }
    const target = args[1]
    if (args[0] === 'forget' && target) {
      await update($, tracked, list => list.filter(t => !t.handle.startsWith(target)))
      return { text: `${target} 를 목록에서 뺐습니다.` }
    }
    if (args[0] === 'add' && args[1]) {
      await track($, args.slice(1).flatMap(a => a.match(HANDLE) ?? []))
      return { text: '터미널을 목록에 넣었습니다.' }
    }
    await $.ui.open({ id: PANE, title: '맡긴 세션' })
    return { text: '맡긴 세션 패널을 열었습니다.' }
  }).catch(() => ({ text: '맡긴 세션 명령을 처리하지 못했습니다.' }))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const visible = (await rows($)).filter(r =>
      !((r.snap.state === 'exited' || r.snap.state === 'gone') && r.now - r.snap.changedAt > HIDE_ENDED_MS))
    if (visible.length === 0) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const width = e.props.bodyColumns || 100
    let used = 6
    const shown = visible.filter(r => {
      used += r.snap.label.length + 12
      return used <= width
    })
    const rest = visible.length - shown.length
    return (
      <Box flexDirection="row" gap={1}>
        <Text dimColor>위임</Text>
        {shown.map(r => (
          <Button key={r.handle} plain onPress={() => jump($, r.handle, r.snap.label)}>
            <Text color={COLOR[r.snap.state]} dimColor={!COLOR[r.snap.state]}>{ICON[r.snap.state]}</Text> {r.snap.label}{' '}
            <Text dimColor>{r.snap.state === 'done' && r.snap.pr ? `PR #${r.snap.pr}` : r.snap.state === 'running' ? '' : ago(r.now - r.snap.changedAt)}</Text>
          </Button>
        ))}
        {rest > 0 && <Text dimColor>+{rest}</Text>}
        <Button key="more" plain dimColor label="자세히" onPress={() => void $.ui.open({ id: PANE, title: '맡긴 세션' })} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const list = await rows($)
    if (list.length === 0) {
      return <Text dimColor>맡긴 세션이 없습니다. orca terminal create·agent launch 로 띄운 탭이 여기 보입니다.</Text>
    }
    return (
      <Box flexDirection="column" gap={1}>
        {list.map(r => (
          <Box key={r.handle} flexDirection="column">
            <Box flexDirection="row" gap={1}>
              <Button key={`go-${r.handle}`} onPress={() => jump($, r.handle, r.snap.label)}>
                <Text color={COLOR[r.snap.state]}>{ICON[r.snap.state]}</Text> {r.snap.label}
              </Button>
              <Text>{WORD[r.snap.state]}</Text>
              <Text dimColor>· 화면 변화 {ago(r.now - r.snap.changedAt)} 전</Text>
              <Button key={`rm-${r.handle}`} plain dimColor label="빼기"
                onPress={() => update($, tracked, l => l.filter(t => t.handle !== r.handle))} />
            </Box>
            {r.snap.lastLines.map(l => <Text dimColor>  {l.slice(0, 120)}</Text>)}
          </Box>
        ))}
      </Box>
    )
  })
}
