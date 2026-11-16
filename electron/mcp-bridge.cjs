#!/usr/bin/env node
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { spawn } = require('node:child_process')
const readline = require('node:readline')
const configFile = () =>
  process.env.OPENTALON_MCP_CONFIG ||
  path.join(os.homedir(), 'Library', 'Application Support', 'OpenTalon Prototype', 'mcp.json')
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
let launchJob
function readConfig(file) {
  const info = fs.statSync(file)
  if ((info.mode & 0o077) !== 0 || (process.getuid && info.uid !== process.getuid()))
    throw new Error('OpenTalon connection file must be owned by you and readable only by you.')
  const config = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (!config.enabled)
    throw new Error(
      'OpenTalon’s MCP connection is disabled. Enable it locally in Settings → Agent connection.'
    )
  if (
    typeof config.token !== 'string' ||
    config.token.length < 32 ||
    !path.isAbsolute(config.executable) ||
    !Array.isArray(config.launchArgs) ||
    !config.launchArgs.every((arg) => typeof arg === 'string')
  )
    throw new Error(
      'OpenTalon’s connection configuration is invalid. Reopen the app to repair setup.'
    )
  return config
}
async function request(config, message) {
  return fetch(`http://127.0.0.1:${config.port}/mcp`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
      Authorization: `Bearer ${config.token}`,
    },
    body: JSON.stringify(message),
    signal: AbortSignal.timeout(60000),
  })
}
async function ready(file) {
  const config = readConfig(file)
  const env = { ...process.env, OPENTALON_PROFILE: config.profile }
  delete env.ELECTRON_RUN_AS_NODE
  const child = spawn(config.executable, [...config.launchArgs, '--background'], {
    detached: true,
    stdio: 'ignore',
    env,
  })
  let launchError
  child.on('error', (error) => {
    launchError = error
  })
  child.unref()
  for (let attempt = 0; attempt < 100; attempt++) {
    if (launchError) throw new Error('OpenTalon could not start. Check the installed app path.')
    await pause(150)
    const latest = readConfig(file)
    try {
      const response = await request(latest, { jsonrpc: '2.0', id: 'ready', method: 'ping' })
      if (response.ok) return latest
    } catch {}
  }
  throw new Error(
    'OpenTalon did not become ready. Open the app to check its local database or connection error.'
  )
}
async function forward(message, file = configFile()) {
  const fail = (messageText) =>
    message?.id !== undefined
      ? { jsonrpc: '2.0', id: message.id, error: { code: -32000, message: messageText } }
      : null
  try {
    let config = readConfig(file),
      response
    try {
      response = await request(config, message)
    } catch {
      if (process.env.OPENTALON_MCP_NO_LAUNCH === '1') return fail('This chat connection is closed.')
      launchJob ||= ready(file).finally(() => {
        launchJob = null
      })
      config = await launchJob
      // Every mutation carries a durable requestKey; retrying an uncertain response is safe.
      response = await request(config, message)
    }
    if (response.status === 202 || response.status === 204) return null
    if (response.status === 401) {
      config = readConfig(file)
      response = await request(config, message)
    }
    if (!response.ok)
      return fail(
        `OpenTalon refused this request (${response.status}). Check the local connection settings.`
      )
    return await response.json()
  } catch (error) {
    return fail(
      error.code === 'ENOENT'
        ? 'OpenTalon is not set up. Open the app and enable Settings → Agent connection.'
        : error.message
    )
  }
}
function main() {
  const lines = readline.createInterface({ input: process.stdin })
  let queue = Promise.resolve()
  lines.on('line', (line) => {
    queue = queue.then(async () => {
      let response
      try {
        if (Buffer.byteLength(line) > 1024 * 1024) throw new Error('Request too large.')
        response = await forward(JSON.parse(line))
      } catch {
        response = {
          jsonrpc: '2.0',
          id: null,
          error: { code: -32700, message: 'Invalid or oversized JSON message.' },
        }
      }
      if (response) process.stdout.write(`${JSON.stringify(response)}\n`)
    })
  })
  lines.on('close', () => {
    queue.then(() => {
      process.exitCode = 0
    })
  })
}
if (require.main === module) main()
module.exports = { forward, configFile, readConfig, main }
