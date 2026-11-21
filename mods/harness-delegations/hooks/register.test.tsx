import { expect, mock, test } from 'claude-code/testing'

import { classify, contentLines, findHeir, handlesFromSpawn, prOf, handlesFromTranscript, labelOf } from './register'

const H1 = 'term_11111111-2222-3333-4444-555555555555'
const H2 = 'term_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

const BAND = {
  plugin: 'harness-delegations',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 3, bodyColumns: 100, scroll: { offset: 0, bodyRows: 3 }, view: {} },
} as const

test('spawn output and wait-delegation commands yield handles', () => {
  expect(handlesFromSpawn('orca terminal create --json', `{"handle":"${H1}"}`)).toEqual([H1])
  expect(handlesFromSpawn(`scripts/wait-delegation.sh --done x --terminal ${H2}`, '')).toEqual([H2])
  expect(handlesFromSpawn('orca terminal read --terminal x', `${H1}`)).toEqual([])
})

test('transcript replay finds handles spawned earlier', () => {
  const lines = [
    { message: { content: [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'orca agent launch claude' } }] } },
    { message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: [{ type: 'text', text: `launched ${H1}` }] }] } },
    { message: { content: [{ type: 'tool_use', id: 't2', name: 'Bash', input: { command: 'orca terminal list' } }] } },
    { message: { content: [{ type: 'tool_result', tool_use_id: 't2', content: `${H2}` }] } },
  ].map(l => JSON.stringify(l)).join('\n')
  expect(handlesFromTranscript(lines)).toEqual([H1])
})

test('screen classification matches wait-delegation', () => {
  const rule = '─'.repeat(40)
  expect(classify(['✻ Working… (esc to interrupt)'], 'running', 5_000)).toBe('running')
  expect(classify(['✻ Working… (esc to interrupt)'], 'running', 11 * 60_000)).toBe('stalled')
  expect(classify(['Do you want to proceed?', '❯ 1. Yes'], 'running', 30_000)).toBe('asking')
  expect(classify(['이 방향으로 진행할까요?', rule, '❯', rule, 'ctx 3%'], 'running', 30_000)).toBe('asking')
  expect(classify(['이 방향으로 진행할까요?'], 'running', 5_000)).toBe('running')
  expect(classify(['done.', rule, '❯', rule, 'ctx 10% | 1h 20m', '⏵⏵ bypass · PR #452'], 'running', 30_000)).toBe('done')
  expect(classify(['done.', '>'], 'running', 30_000)).toBe('idle')
  expect(classify([], 'exited', 0)).toBe('exited')
})

test('the last PR on screen is the one reported', () => {
  expect(prOf(['opened https://github.com/o/r/pull/12', '· PR #452'])).toBe('452')
  expect(prOf(['https://bitbucket.org/o/r/pull-requests/7'])).toBe('7')
  expect(prOf(['no pr here'])).toBeUndefined()
})

test('the status line under the prompt does not count as screen change', () => {
  const rule = '─'.repeat(40)
  const at = (clock: string) => ['결과 정리 완료', rule, '❯ ', rule, `ctx 29% | ${clock} | $7.51`]
  expect(contentLines(at('4h 58m'))).toEqual(contentLines(at('4h 59m')))
  expect(contentLines(['a', 'b'])).toEqual(['a', 'b'])
})

test('a closed tab hands over to the live tab of the same worktree', () => {
  const live = [
    { handle: H2, worktreePath: '/w/a', orphaned: false },
    { handle: 'term_x', worktreePath: '', orphaned: false },
  ]
  expect(findHeir(live, '/w/a', new Set())?.handle).toBe(H2)
  expect(findHeir(live, '/w/a', new Set([H2]))).toBeUndefined()
  expect(findHeir(live, '', new Set())).toBeUndefined()
})

test('labels drop spinner glyphs and fall back to branch', () => {
  expect(labelOf({ title: '⠂ api-server 작업' })).toBe('api-server 작업')
  expect(labelOf({ title: '', branch: 'refs/heads/feat/x' })).toBe('feat/x')
  expect(labelOf({ worktreePath: '/a/b/web-front' })).toBe('web-front')
})

test('a spawned terminal shows on the band, alerts when it asks, and a press jumps to it', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.env(on, { ORCA_TERMINAL_HANDLE: H2 })
  let screen = ['✻ Working… (esc to interrupt)']
  let alive = true
  const switched: string[] = []
  const toasts: string[] = []
  on('process.run', (_, e) => {
    const argv = (e as { argv: string[] }).argv
    const ok = (result: unknown) => ({ value: { exitCode: 0, stdout: JSON.stringify({ ok: true, result }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    if (argv[2] === 'list') return ok({ terminals: [...(alive ? [{ handle: H1, title: '⠂ api-server', branch: 'feat/x' }] : []), { handle: H2, title: 'me' }] })
    if (argv[2] === 'show') return ok({ terminal: { handle: H1, worktreePath: '' } })
    if (argv[2] === 'read') return ok({ terminal: { handle: H1, status: 'running', tail: screen } })
    if (argv[2] === 'switch') { switched.push(argv[4] ?? ''); return ok({}) }
    return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.toast', (_, e) => { toasts.push(String((e as { text: string }).text)); return { value: undefined } })
  const prompts: string[] = []
  on('prompt.submit', (_, e) => { prompts.push(String((e as { text: string }).text)); return { text: (e as { text: string }).text } as never })
  on('command.register', () => ({ value: { command: 'harness-delegations' } }))
  on('session.info', () => ({ value: { transcriptPath: '' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: { stdout: `{"handle":"${H1}"}`, stderr: '', interrupted: false } }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'orca terminal create --json' })
  await clock.settle()

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await ui.find({ key: H1 }))?.text).toContain('api-server')
  expect(await ui.find({ key: H2 })).toBeUndefined()

  screen = ['Do you want to proceed?', '❯ 1. Yes']
  for (let i = 0; i < 3; i++) await clock.advance(15_000)
  expect(toasts.join(' ')).toContain('api-server 입력 대기')
  expect(prompts.join('\n')).toContain(H1)
  expect(prompts.join('\n')).toContain('입력 대기')

  await ui.press({ key: H1 })
  expect(switched).toEqual([H1])

  screen = ['PR 올림', '⏵⏵ bypass · PR #452']
  for (let i = 0; i < 3; i++) await clock.advance(15_000)
  alive = false
  await clock.advance(15_000)
  expect((await ui.find({ key: H1 }))?.text).toContain('PR #452')
  expect(prompts.join('\n')).toContain('완료 · PR #452')
  expect(prompts.join('\n')).not.toContain('api-server 종료')
  await ui.unmount()
})

test('band stays empty with nothing tracked', async ($, on) => {
  mock.clock(on)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /위임/ })).toBeUndefined()
  await ui.unmount()
})
