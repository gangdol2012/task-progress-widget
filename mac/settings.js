// Edits Claude's settings.json for install.command and uninstall.command,
// keeping every other setting, and the order of keys, as they were. Runs on
// the JavaScript for Automation that every Mac has, so nothing to install.
//
//   osascript -l JavaScript settings.js install <settings.json> <mod folder> <hook binary> <1|0: add hooks>
//   osascript -l JavaScript settings.js uninstall <settings.json> <mod folder>...
//
// Prints what it did, one line each. Saves a backup next to the file before
// changing it. If the file isn't valid JSON it changes nothing and fails
// with NOT_JSON.

ObjC.import('Foundation')

// The terminal hooks, as on Windows: event -> matcher (null: every one).
const HOOK_EVENTS = [
  ['UserPromptSubmit', null],
  ['PreToolUse', 'AskUserQuestion|ExitPlanMode'],
  ['PostToolUse', '*'],
  ['TaskCreated', null],
  ['TaskCompleted', null],
  ['Stop', null],
  ['SessionEnd', null],
  ['Notification', 'permission_prompt|elicitation_dialog|agent_needs_input'],
]

const fm = $.NSFileManager.defaultManager

// Edit the file a link points at, not the link (dotfiles are often links).
function realPath(path) {
  return $(path).stringByResolvingSymlinksInPath.js
}

function readText(path) {
  if (!fm.fileExistsAtPath(path)) return null
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  if (s.isNil()) throw new Error(`Could not read ${path}`)
  return s.js
}

// Written in place (not replaced), so the file keeps its permissions.
function writeText(path, text) {
  if (!$(text).writeToFileAtomicallyEncodingError(path, false, $.NSUTF8StringEncoding, null)) {
    throw new Error(`Could not write ${path}`)
  }
}

function backup(path) {
  const d = new Date()
  const p = n => String(n).padStart(2, '0')
  const stamp = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
  let to = `${path}.bak-${stamp}`
  for (let n = 2; fm.fileExistsAtPath(to); n++) to = `${path}.bak-${stamp}-${n}`
  if (!fm.copyItemAtPathToPathError(path, to, null)) throw new Error(`Could not back up ${path}`)
  return to
}

function parse(raw) {
  if (raw === null || raw.replace(/^﻿/, '').trim() === '') return {}
  let cfg
  try {
    cfg = JSON.parse(raw.replace(/^﻿/, ''))
  } catch (e) {
    throw new Error('NOT_JSON')
  }
  if (cfg === null) return {}
  if (typeof cfg !== 'object' || Array.isArray(cfg)) throw new Error('NOT_JSON')
  return cfg
}

const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v)

// Ours: a hook that runs this widget's hook, the Mac binary or the Windows
// script, wherever it was installed.
function isOurs(hook) {
  if (!isObject(hook)) return false
  const parts = [hook.command].concat(Array.isArray(hook.args) ? hook.args : [])
  const text = parts.filter(x => typeof x === 'string').join(' ')
  return /task-progress-bar[\\/]cli[\\/]progress-hook/.test(text) || /progress-hook\.ps1/.test(text)
}
const groupIsOurs = g => isObject(g) && Array.isArray(g.hooks) && g.hooks.some(isOurs)

// Quote for /bin/sh, which runs a hook's command.
const shq = s => `'${s.replace(/'/g, `'\\''`)}'`

// CLAUDE_CODE_PLUGIN_DIRS is a list of folders separated by ':' on a Mac,
// each maybe starting with ~.
const splitDirs = v => v.split(':').map(s => s.trim()).filter(Boolean)
const expand = d => $(d).stringByExpandingTildeInPath.stringByStandardizingPath.js
const sameDir = (a, b) => expand(a) === expand(b)

function install(settings, modDir, hookBin, withHooks) {
  const path = realPath(settings)
  const raw = readText(path)
  const cfg = parse(raw)
  const said = []

  if (cfg.env === undefined) cfg.env = {}
  if (!isObject(cfg.env)) {
    said.push(`"env" in ${settings} isn't a list of settings, so the mod wasn't turned on.`)
    said.push(`Add it by hand:  "env": { "CLAUDE_CODE_PLUGIN_DIRS": "${modDir}" }`)
  } else {
    const cur = cfg.env.CLAUDE_CODE_PLUGIN_DIRS
    if (typeof cur === 'string' && cur.trim() && !splitDirs(cur).some(d => sameDir(d, modDir))) {
      // Another mod folder is already loaded: keep it and add ours.
      cfg.env.CLAUDE_CODE_PLUGIN_DIRS = `${cur}:${modDir}`
      said.push('[ok] Mod turned on (Claude desktop app), next to the mod folder you already had:')
      said.push(`     ${cur}`)
    } else if (typeof cur === 'string' && cur.trim()) {
      // setup.sh reads this line: Claude already loads the mod folder.
      said.push('[ok] Mod already turned on (Claude desktop app)')
    } else {
      cfg.env.CLAUDE_CODE_PLUGIN_DIRS = modDir
      said.push('[ok] Mod turned on (Claude desktop app)')
    }
  }

  // Hooks for Claude Code in a terminal. Any earlier copy of ours is
  // replaced; other hooks are left as they are.
  if (cfg.hooks === undefined && withHooks) cfg.hooks = {}
  if (isObject(cfg.hooks)) {
    for (const [ev, matcher] of HOOK_EVENTS) {
      const had = cfg.hooks[ev]
      if (had !== undefined && !Array.isArray(had)) continue  // not ours to fix
      const groups = (had || []).filter(g => !groupIsOurs(g))
      if (withHooks) {
        const group = {}
        if (matcher) group.matcher = matcher
        group.hooks = [{ type: 'command', command: `${shq(hookBin)} ${ev}`, async: true }]
        groups.push(group)
      }
      if (groups.length) cfg.hooks[ev] = groups
      else delete cfg.hooks[ev]
    }
    if (withHooks) said.push('[ok] Hooks added for Claude Code in a terminal')
  } else if (withHooks) {
    said.push(`"hooks" in ${settings} isn't a list of hooks, so the terminal hooks weren't added.`)
  }

  if (raw !== null) said.push(`[ok] Your old settings are saved as ${backup(path)}`)
  writeText(path, JSON.stringify(cfg, null, 2) + '\n')
  return said.join('\n')
}

function uninstall(settings, ours) {
  const path = realPath(settings)
  const raw = readText(path)
  if (raw === null) return ''
  const cfg = parse(raw)
  let changed = false

  if (isObject(cfg.env) && typeof cfg.env.CLAUDE_CODE_PLUGIN_DIRS === 'string') {
    const dirs = splitDirs(cfg.env.CLAUDE_CODE_PLUGIN_DIRS)
    const keep = dirs.filter(d => !ours.some(o => sameDir(d, o)))
    if (keep.length !== dirs.length) {
      changed = true
      if (keep.length) cfg.env.CLAUDE_CODE_PLUGIN_DIRS = keep.join(':')
      else delete cfg.env.CLAUDE_CODE_PLUGIN_DIRS
    }
  }
  // Our terminal hooks (any entry that runs progress-hook); others stay.
  if (isObject(cfg.hooks)) {
    for (const ev of Object.keys(cfg.hooks)) {
      const before = cfg.hooks[ev]
      if (!Array.isArray(before)) continue
      const keep = before.filter(g => !groupIsOurs(g))
      if (keep.length !== before.length) {
        changed = true
        if (keep.length) cfg.hooks[ev] = keep
        else delete cfg.hooks[ev]
      }
    }
    if (changed && !Object.keys(cfg.hooks).length) delete cfg.hooks
  }
  if (changed && isObject(cfg.env) && !Object.keys(cfg.env).length) delete cfg.env
  if (!changed) return ''
  const saved = backup(path)
  writeText(path, JSON.stringify(cfg, null, 2) + '\n')
  return `[ok] Removed from ${settings} (old copy saved as ${saved})`
}

function run(argv) {
  const [cmd, settings, ...rest] = argv
  if (cmd === 'install') return install(settings, rest[0], rest[1], rest[2] === '1')
  if (cmd === 'uninstall') return uninstall(settings, rest)
  throw new Error(`unknown command: ${cmd}`)
}
