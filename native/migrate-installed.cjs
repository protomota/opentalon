// One-time cutover for the original macOS installation. The old app profile is
// archived intact and its discovery path remains usable by installed MCP clients.
const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { createHash, randomUUID } = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { DatabaseSync, backup } = require('node:sqlite')
const { setTimeout: pause } = require('node:timers/promises')
const { Store } = require('./runtime/store.cjs')

const support = process.env.OPENTALON_CUTOVER_TEST_SUPPORT ||
  path.join(os.homedir(), 'Library', 'Application Support')
const legacy = path.join(support, 'OpenTalon Prototype')
const native = path.join(support, 'OpenTalon Native')
const source = path.join(legacy, 'opentalon.sqlite')
const configFile = path.join(legacy, 'mcp.json')

function digest(db) {
  const result = createHash('sha256')
  assert.deepEqual(db.prepare('PRAGMA quick_check').get().quick_check, 'ok')
  assert.equal(db.prepare('PRAGMA foreign_key_check').all().length, 0)
  for (const { name, sql } of db.prepare(
    "SELECT name, sql FROM sqlite_schema WHERE type='table' ORDER BY name"
  ).all()) {
    assert.match(name, /^[a-z_][a-z_0-9]*$/i)
    result.update(sql || name)
    for (const row of db.prepare(`SELECT * FROM "${name}" ORDER BY rowid`).iterate())
      result.update(JSON.stringify(row)).update('\n')
  }
  return result.digest('hex')
}

function summary(db) {
  const count = (table, filter = '') => db.prepare(`SELECT count(*) AS n FROM ${table} ${filter}`).get().n
  return {
    projects: count('boards'), liveTasks: count('tasks', 'WHERE deleted_at IS NULL'),
    trash: count('tasks', 'WHERE deleted_at IS NOT NULL'), comments: count('task_comments'),
    screenshots: count('comment_images'), runHistory: count('agent_jobs'),
  }
}

function assertNoAgentRuns(db) {
  assert.equal(db.prepare(`SELECT count(*) AS n FROM agent_jobs
    WHERE json_extract(data,'$.state') IN ('queued','starting','working','needs-input')`).get().n, 0,
  'Stop or finish active runs before switching the workspace.')
}

async function copyWorkspace(destination, exact) {
  const db = new DatabaseSync(source, { readOnly: true })
  try {
    assertNoAgentRuns(db)
    await backup(db, destination)
    fs.chmodSync(destination, 0o600)
    const clone = new DatabaseSync(destination, { readOnly: true })
    try {
      const hash = digest(clone)
      if (exact) assert.equal(hash, digest(db), 'Workspace changed after the copy.')
      return { ...summary(clone), checksum: hash }
    } finally { clone.close() }
  } finally { db.close() }
}

function writers() {
  try {
    return execFileSync('/usr/sbin/lsof', ['-t', source], { encoding: 'utf8' })
      .trim().split(/\s+/).filter(Boolean).map(Number)
  } catch (error) {
    if (error.status === 1) return []
    throw error
  }
}

function verifyWriter(pid, executable) {
  const real = fs.realpathSync(executable)
  assert.match(real, /\/(Electron|OpenTalon)\.app\/Contents\/MacOS\/(Electron|OpenTalon)$/)
  const processInfo = execFileSync('/usr/sbin/lsof', ['-a', '-p', String(pid), '-d', 'txt', '-Fn'],
    { encoding: 'utf8' }).split('\n')
  assert.ok(processInfo.includes('n' + real), 'An unexpected process owns the Electron database.')
}

function writeJSON(file, value) {
  const temporary = file + '.' + randomUUID()
  fs.writeFileSync(temporary, JSON.stringify(value) + '\n', { mode: 0o600, flag: 'wx' })
  try { fs.renameSync(temporary, file) }
  finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary) }
}

async function prepare(recovery) {
  fs.mkdirSync(recovery, { mode: 0o700 })
  const stage = path.join(recovery, 'portable-stage')
  fs.mkdirSync(stage, { mode: 0o700 })
  const result = await copyWorkspace(path.join(stage, 'opentalon.sqlite'), false)
  const copy = new Store(stage)
  try { await copy.createBackup(path.join(recovery, 'OpenTalon-before-native.json'), 'json') }
  finally { copy.close() }
  fs.writeFileSync(path.join(recovery, 'preflight.json'), JSON.stringify(result, null, 2) + '\n', { mode: 0o600 })
  console.log(JSON.stringify({ recovery, ...result }))
}

async function switchProfiles(recovery, app) {
  assert.ok(fs.existsSync(path.join(recovery, 'OpenTalon-before-native.json')), 'Run prepare first.')
  assert.ok(!fs.existsSync(native), 'A native profile already exists; it will not be replaced.')
  const executable = path.join(app, 'Contents', 'MacOS', 'OpenTalon')
  fs.accessSync(executable, fs.constants.X_OK)
  const previous = JSON.parse(fs.readFileSync(configFile, 'utf8'))
  assert.equal(previous.profile, legacy)
  const reader = new DatabaseSync(source, { readOnly: true })
  try { assertNoAgentRuns(reader) } finally { reader.close() }
  for (const pid of writers()) verifyWriter(pid, previous.executable)

  const target = fs.mkdtempSync(path.join(support, '.OpenTalon-Native-'))
  const stub = fs.mkdtempSync(path.join(support, '.OpenTalon-Retired-'))
  const archive = path.join(support, `OpenTalon Electron Archive ${new Date().toISOString().replaceAll(':', '-')}`)
  let oldMoved = false
  let targetMoved = false
  let stubMoved = false
  try {
    // Prevent old stdio clients from restarting Electron between shutdown and cutover.
    writeJSON(configFile, { ...previous, enabled: false, port: 0 })
    for (const pid of writers()) {
      verifyWriter(pid, previous.executable)
      process.kill(pid, 'SIGTERM')
    }
    for (let attempt = 0; attempt < 60 && writers().length > 0; attempt++) await pause(100)
    assert.deepEqual(writers(), [], 'Electron is still using the workspace. Quit it before retrying.')
    writeJSON(configFile, { ...previous, enabled: false, port: 0 })
    const result = await copyWorkspace(path.join(target, 'opentalon.sqlite'), true)
    fs.copyFileSync(path.join(target, 'opentalon.sqlite'), path.join(recovery, 'OpenTalon-final.sqlite'),
      fs.constants.COPYFILE_EXCL)
    fs.chmodSync(path.join(recovery, 'OpenTalon-final.sqlite'), 0o600)
    writeJSON(path.join(target, 'mcp.json'), {
      enabled: previous.enabled === true, token: previous.token, port: 0,
      executable, launchArgs: [], profile: native,
    })
    fs.writeFileSync(path.join(stub, 'opentalon.sqlite'),
      'The original OpenTalon workspace has moved to the native Swift app. This is not a database.\n',
      { mode: 0o600 })
    fs.symlinkSync(path.join(native, 'mcp.json'), path.join(stub, 'mcp.json'))
    fs.writeFileSync(path.join(stub, 'README.txt'),
      `OpenTalon's single active workspace is now at:\n${native}\n\nThe archived Electron profile is at:\n${archive}\n`,
      { mode: 0o600 })
    assert.deepEqual(writers(), [], 'The Electron workspace reopened. Retry the cutover.')
    assert.ok(!fs.existsSync(native), 'A native workspace opened during migration.')
    fs.renameSync(legacy, archive)
    oldMoved = true
    writeJSON(path.join(archive, 'mcp.json'), { ...previous, enabled: false, port: 0 })
    fs.renameSync(target, native)
    targetMoved = true
    fs.renameSync(stub, legacy)
    stubMoved = true
    const receipt = { ...result, archive, profile: native, legacyDiscovery: 'redirected to native' }
    writeJSON(path.join(recovery, 'cutover.json'), receipt)
    console.log(JSON.stringify(receipt))
  } catch (error) {
    if (stubMoved) fs.renameSync(legacy, stub)
    if (targetMoved) fs.renameSync(native, target)
    if (oldMoved) fs.renameSync(archive, legacy)
    writeJSON(configFile, previous)
    throw error
  } finally {
    // These paths are private staging directories created by this invocation.
    fs.rmSync(target, { recursive: true, force: true })
    fs.rmSync(stub, { recursive: true, force: true })
  }
}

async function main() {
  const [mode, recovery, app] = process.argv.slice(2)
  assert.ok(recovery && path.isAbsolute(recovery), 'Supply a private recovery folder on Expand.')
  if (mode === 'prepare') await prepare(recovery)
  else if (mode === 'switch') {
    assert.ok(app && path.isAbsolute(app), 'Supply the verified native app bundle.')
    await switchProfiles(recovery, app)
  } else throw new Error('Use prepare <recovery folder> or switch <recovery folder> <native app>.')
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
