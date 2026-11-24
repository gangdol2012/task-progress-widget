import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Progress, Waiting } from '../types'

// One file per session in <home>/.claude/task-progress; the floating widget
// reads them all and shows a row for each session that is working.
let stateDir = ''

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function getStateDir($: any): Promise<string> {
  if (!stateDir) {
    let home = ''
    try {
      // USERPROFILE on Windows, HOME on macOS.
      home = (await $.env.get('USERPROFILE')) || (await $.env.get('HOME')) || ''
    } catch (err) {
      await noteError($, 'env.get', err)
    }
    if (home) {
      stateDir = `${home.replace(/\\/g, '/')}/.claude/task-progress`
    } else {
      // The installer puts the mod in <home>/.claude/mods/task-progress-bar.
      const root = String($.plugin.root).replace(/\\/g, '/')
      stateDir = `${root.replace(/\/mods\/[^/]+\/?$/, '')}/task-progress`
    }
  }
  return stateDir
}

// Keep the last error in the mod's own folder, so a silent failure can be
// found without a debugger.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function noteError($: any, where: string, err: unknown): Promise<void> {
  try {
    await $.fs.write(
      `${String($.plugin.root).replace(/\\/g, '/')}/last-error.txt`,
      `${new Date().toISOString()} ${where}: ${String(err)}\n`,
    )
  } catch {
    // nowhere left to report it
  }
}

const PROMPT_CHARS = 60
// Messages shorter than this, or of 3 words or fewer, don't rename the row.
const MIN_NAME_CHARS = 20

// The app's task-list tool. Full `items` on any plan change; `advance` / `done`
// ride along on step transitions.
const PLAN_TOOL = 'mcp__ccd_turn__update_plan'
// The app's end-of-turn box; `blocked: true` means the turn ends on a
// question the person must answer.
const WRAP_UP_TOOL = 'mcp__ccd_turn__wrap_up'
// Tools that wait for the person while they run.
const PERSON_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])

// Guess for a step's length before any history exists (20s).
const DEFAULT_STEP_MS = 20000
// Learning rate for the rolling average of step length.
const EMA = 0.3
// Clamp a single step's measured length so one very long or very short step
// cannot swing the average wildly.
const MIN_STEP_MS = 1000
const MAX_STEP_MS = 300000
const AVG_KEY = 'avgStepMs'

const empty: Progress = {
  total: 0,
  completed: 0,
  label: '',
  done: false,
  running: false,
  stepStartedAt: 0,
  prompt: '',
  waiting: '',
}

const progress = atom(
  { plugin: 'task-progress-bar', key: 'progress' } as const,
  empty,
)

type PlanItem = { content?: string; status?: string }

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function getAvgMs($: any): Promise<number> {
  try {
    const v = await $.store.get(AVG_KEY)
    if (typeof v === 'number' && v > 0) return v
  } catch {
    // fall through to default
  }
  return DEFAULT_STEP_MS
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function recordStepMs($: any, durMs: number): Promise<void> {
  const d = Math.max(MIN_STEP_MS, Math.min(MAX_STEP_MS, durMs))
  const avg = await getAvgMs($)
  const next = Math.round(avg * (1 - EMA) + d * EMA)
  try {
    await $.store.set(AVG_KEY, next)
  } catch {
    // ignore: estimate stays at the old value
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function persist($: any): Promise<void> {
  const p = await read($, progress)
  let ts = 0
  try {
    ts = await $.clock.now()
  } catch {
    ts = 0
  }
  const avgStepMs = await getAvgMs($)
  try {
    const sid = String(await $.session.id()).replace(/[^A-Za-z0-9_-]/g, '_')
    await $.fs.write(
      `${await getStateDir($)}/${sid}.json`,
      JSON.stringify({ ...p, avgStepMs, ts, source: 'desktop' }),
    )
  } catch (err) {
    // never let a failed write break a turn
    await noteError($, 'persist', err)
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function setWaiting($: any, waiting: Waiting): Promise<void> {
  const prev = await read($, progress)
  if (prev.waiting === waiting) return
  await update($, progress, p => ({ ...p, waiting }))
  await persist($)
}

export const register: Register = on => {
  let ticker: { cancel: () => void } | null = null
  // Step names from the last full plan, so `advance` / `start` can show the
  // name of the step now running.
  let stepNames: string[] = []

  const stopTicker = (): void => {
    if (ticker) {
      ticker.cancel()
      ticker = null
    }
  }

  // The turn ended on a question for the person (wrap_up with `blocked`).
  let endsOnQuestion = false

  on('session.start', async ($, e, next) => {
    await update($, progress, (p): Progress => ({ ...p, running: false, waiting: '' }))
    await persist($)
    return next(e)
  })

  // Heartbeat: refresh the widget's timestamp on every tool call, so the
  // widget can tell "working now" from "finished" by how fresh the file is.
  // A tool that needs the person (a question, a plan to approve) marks the
  // session as waiting until it returns. Permission prompts are flagged by
  // the terminal hook instead (cli/progress-hook.ps1 on Windows,
  // cli/progress-hook on macOS; Notification event): the mod can't tell a
  // prompt shown to the person from one auto mode settles.
  on('tool.call', async ($, e, next) => {
    await persist($)
    const tool = String((e as { tool?: unknown }).tool ?? '')
    if (PERSON_TOOLS.has(tool)) await setWaiting($, 'question')
    if (tool === WRAP_UP_TOOL) {
      endsOnQuestion = (e as { blocked?: unknown }).blocked === true
    }
    try {
      return await next(e)
    } finally {
      if ((await read($, progress)).waiting) await setWaiting($, '')
    }
  })

  on('prompt.submit', async ($, e, next) => {
    const now = await $.clock.now()
    // New turn: forget the last turn's task list so a turn without one shows
    // as "working" instead of a stale bar.
    const typed = String((e as { text?: unknown }).text ?? '')
      .replace(/\s+/g, ' ')
      .trim()
    // A short reply ("yes", "ok, do it") says nothing about the session, so
    // keep the last longer message as the row name.
    const isShort =
      typed.length < MIN_NAME_CHARS || typed.split(' ').length <= 3
    endsOnQuestion = false
    await update($, progress, (prev): Progress => ({
      total: 0,
      completed: 0,
      label: '',
      running: true,
      done: false,
      stepStartedAt: now,
      prompt:
        isShort && prev.prompt ? prev.prompt : typed.slice(0, PROMPT_CHARS),
      waiting: '',
    }))
    await persist($)

    // Heartbeat the file about once a second while the turn runs, so the widget
    // does not falsely show "finished" during a long quiet step.
    stopTicker()
    ticker = $.clock.every(1000, () => {
      void persist($)
    })

    return next(e)
  })

  on('tool.call', { tool: PLAN_TOOL }, async ($, e, next) => {
    const args = e as unknown as {
      items?: PlanItem[]
      advance?: boolean
      done?: number[]
      start?: number
    }

    const prev = await read($, progress)
    const now = await $.clock.now()

    let total = prev.total
    let completed = prev.completed
    let label = prev.label

    if (Array.isArray(args.items)) {
      stepNames = args.items.map(it => it?.content ?? '')
      total = args.items.length
      completed = args.items.filter(it => it?.status === 'completed').length
      const active = args.items.find(it => it?.status === 'in_progress')
      label = active?.content ?? ''
    } else {
      if (args.advance) completed += 1
      if (Array.isArray(args.done) && args.done.length) {
        completed = Math.max(completed, args.done.length)
      }
    }
    completed = Math.max(0, Math.min(total, completed))
    if (!Array.isArray(args.items)) {
      // The running step is the one `start` names, else the next after the
      // completed ones (steps run in order).
      const idx =
        typeof args.start === 'number' ? args.start - 1 : completed
      label = stepNames[idx] ?? ''
    }

    // Learn step length from any steps that just finished; reset the clock for
    // the step now in progress.
    let stepStartedAt = prev.stepStartedAt
    if (completed > prev.completed && prev.stepStartedAt > 0) {
      const stepsDone = completed - prev.completed
      await recordStepMs($, (now - prev.stepStartedAt) / stepsDone)
      stepStartedAt = now
    } else if (completed < prev.completed || prev.stepStartedAt === 0) {
      stepStartedAt = now
    }

    await update($, progress, () => ({
      total,
      completed,
      label,
      done: total > 0 && completed >= total,
      running: true,
      stepStartedAt,
      prompt: prev.prompt,
      waiting: prev.waiting,
    }))
    await persist($)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    // A subagent's turn ending is not the session's.
    if ((e as { agentId?: unknown }).agentId !== undefined) return next(e)
    await update($, progress, (prev): Progress => ({
      ...prev,
      running: false,
      waiting: endsOnQuestion ? 'answer' : '',
    }))
    await persist($)
    stopTicker()
    return next(e)
  })
}
