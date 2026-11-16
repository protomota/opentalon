const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs/promises')
const path = require('node:path')
const { promisify } = require('node:util')
const { execFile, spawn } = require('node:child_process')
const {
  setupFields,
  terminalCommand,
  saveClaudeExtension,
  prepareProjectSetup,
  writeProjectSetup,
} = require('./agent-setup.cjs')
const { validateAction, tools } = require('./contracts.cjs')
const { Store } = require('./store.cjs')
const { Connector } = require('./mcp.cjs')
const run = promisify(execFile)
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'

test('Claude Code project setup preserves other servers, rejects malformed files, links and stale writes', async (t) => {
  const folder = await fs.mkdtemp(path.join(base, 'project-setup-'))
  t.after(() => fs.rm(folder, { recursive: true, force: true }))
  const file = path.join(folder, '.mcp.json')
  const config = {
    mcpServers: {
      opentalon: {
        command: '/Applications/Open Talon',
        args: ['/bridge.cjs'],
        env: { OPENTALON_MCP_CONFIG: '/private/config' },
      },
    },
  }
  await fs.writeFile(
    file,
    JSON.stringify({
      other: true,
      mcpServers: { existing: { command: 'existing', env: { KEY: 'preserve' } } },
    })
  )
  const prepared = prepareProjectSetup(folder, config)
  assert.equal(prepared.replacing, false)
  writeProjectSetup(prepared)
  const saved = JSON.parse(await fs.readFile(file, 'utf8'))
  assert.equal(saved.other, true)
  assert.equal(saved.mcpServers.existing.env.KEY, 'preserve')
  assert.equal(saved.mcpServers.opentalon.type, 'stdio')
  assert.equal(prepareProjectSetup(folder, config).replacing, false)
  assert.equal(
    prepareProjectSetup(folder, {
      mcpServers: { opentalon: { ...config.mcpServers.opentalon, command: '/new' } },
    }).replacing,
    true
  )
  const stale = prepareProjectSetup(folder, config)
  await fs.writeFile(file, '{"changed":true}')
  assert.throws(() => writeProjectSetup(stale), /changed/)
  assert.equal(await fs.readFile(file, 'utf8'), '{"changed":true}')
  for (const invalid of ['{', '[]', '{"mcpServers":[]}']) {
    await fs.writeFile(file, invalid)
    assert.throws(() => prepareProjectSetup(folder, config))
    assert.equal(await fs.readFile(file, 'utf8'), invalid)
  }
  await fs.unlink(file)
  await fs.writeFile(path.join(folder, 'target'), '{}')
  await fs.symlink(path.join(folder, 'target'), file)
  assert.throws(() => prepareProjectSetup(folder, config), /not a link/)
})

test('desktop fields and terminal commands preserve spaces, quotes and shell metacharacters', async (t) => {
  const folder = await fs.mkdtemp(path.join(base, 'setup-'))
  t.after(() => fs.rm(folder, { recursive: true, force: true }))
  const server = {
    command: "/Applications/Brad's $(touch never) App",
    args: ['/a path/bridge.cjs'],
    env: { ELECTRON_RUN_AS_NODE: '1', OPENTALON_MCP_CONFIG: "/a ' quoted/$HOME/config.json" },
  }
  const config = { mcpServers: { opentalon: server } }
  assert.deepEqual(
    setupFields(config).map((field) => field.value),
    ['opentalon', server.command, ...server.args, ...Object.values(server.env)]
  )
  await fs.writeFile(path.join(folder, 'codex'), '#!/bin/sh\n/usr/bin/printf "%s\\n" "$@"\n', {
    mode: 0o700,
  })
  const { stdout } = await run('/bin/zsh', ['-f', '-c', terminalCommand(config, 'codex')], {
    cwd: folder,
    env: { PATH: folder },
  })
  assert.deepEqual(stdout.trim().split('\n'), [
    'mcp',
    'add',
    'opentalon',
    '--env',
    'ELECTRON_RUN_AS_NODE=1',
    '--env',
    `OPENTALON_MCP_CONFIG=${server.env.OPENTALON_MCP_CONFIG}`,
    '--',
    server.command,
    ...server.args,
  ])
  assert.throws(() => terminalCommand(config, 'anything'))
  assert.equal(tools.length, 24)
  for (const name of [
    'agent_setup_fields',
    'save_claude_extension',
    'open_setup_app',
    'copy_setup_field',
  ])
    assert.throws(() => validateAction(name, {}))
  assert.throws(() => validateAction('open_setup_app', { app: '/bin/sh' }, true))
  assert.throws(() =>
    validateAction('open_company_website', { url: 'https://other.example' }, true)
  )
})

test('exported Claude extension contains no key and its bundled bridge connects to the embedded server', async (t) => {
  const folder = await fs.mkdtemp(path.join(base, 'extension-'))
  const store = new Store(path.join(folder, 'profile'))
  const connector = new Connector({
    folder: store.folder,
    call: (name, args) => store.dispatch(name, args),
  })
  t.after(async () => {
    await connector.stop()
    await store.queue
    store.close()
    await fs.rm(folder, { recursive: true, force: true })
  })
  await connector.enable(true)
  const output = path.join(folder, 'OpenTalon.mcpb')
  await saveClaudeExtension(output, connector.file, '0.1.0')
  await run('/usr/bin/unzip', ['-q', output, '-d', path.join(folder, 'unpacked')])
  const manifestText = await fs.readFile(path.join(folder, 'unpacked', 'manifest.json'), 'utf8')
  const manifest = JSON.parse(manifestText)
  assert.equal(manifest.icon, 'icon.png')
  assert.deepEqual(
    await fs.readFile(path.join(folder, 'unpacked', manifest.icon)),
    await fs.readFile(path.join(__dirname, '..', 'assets', 'opentalon-logo-1024.png'))
  )
  assert.equal(manifest.server.type, 'node')
  assert.equal(manifest.server.mcp_config.command, 'node')
  assert.equal(manifest.server.mcp_config.env.OPENTALON_MCP_CONFIG, connector.file)
  const privateConfig = JSON.parse(await fs.readFile(connector.file, 'utf8'))
  assert.ok(!manifestText.includes(privateConfig.token))
  const responses = await new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [
        '-e',
        'require(process.argv[1])',
        path.join(folder, 'unpacked', manifest.server.entry_point),
      ],
      {
        env: { ...process.env, ...manifest.server.mcp_config.env },
        stdio: ['pipe', 'pipe', 'pipe'],
      }
    )
    let stdout = '',
      stderr = ''
    child.stdout.on('data', (chunk) => (stdout += chunk))
    child.stderr.on('data', (chunk) => (stderr += chunk))
    child.on('error', reject)
    child.on('close', (code) =>
      code
        ? reject(new Error(stderr))
        : resolve(
            stdout
              .trim()
              .split('\n')
              .map((line) => JSON.parse(line))
          )
    )
    child.stdin.end(
      JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2025-11-25',
          capabilities: {},
          clientInfo: { name: 'Extension test', version: '1' },
        },
      }) +
        '\n' +
        JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) +
        '\n'
    )
  })
  assert.equal(responses[0].result.serverInfo.name, 'OpenTalon')
  assert.equal(responses[1].result.tools.length, 24)
})
