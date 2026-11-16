const fs = require('node:fs/promises')
const fsSync = require('node:fs')
const { randomUUID } = require('node:crypto')
const path = require('node:path')
const { execFile } = require('node:child_process')
const { promisify } = require('node:util')
const { AppError } = require('./contracts.cjs')
const run = promisify(execFile)

function setupFields(config) {
  const server = config.mcpServers.opentalon
  return [
    { id: 'name', label: 'Name', value: 'opentalon' },
    { id: 'command', label: 'Command', value: server.command },
    ...server.args.map((value, index) => ({
      id: `argument-${index}`,
      label: `Argument ${index + 1}`,
      value,
    })),
    ...Object.entries(server.env).map(([name, value]) => ({ id: name, label: name, value })),
  ]
}
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`
function terminalCommand(config, client) {
  const server = config.mcpServers.opentalon
  const prefix =
    client === 'codex'
      ? ['codex', 'mcp', 'add', 'opentalon']
      : client === 'claude-code'
        ? ['claude', 'mcp', 'add', '--scope', 'user', '--transport', 'stdio', 'opentalon']
        : null
  if (!prefix) throw new AppError('INVALID_ARGUMENT', 'Choose Codex or Claude.')
  return [
    ...prefix,
    ...Object.entries(server.env).flatMap(([name, value]) => ['--env', `${name}=${value}`]),
    '--',
    server.command,
    ...server.args,
  ]
    .map(quote)
    .join(' ')
}
async function saveClaudeExtension(destination, configFile, version) {
  const staging = await fs.mkdtemp(path.join(path.dirname(destination), '.opentalon-extension-'))
  try {
    const manifest = {
      manifest_version: '0.3',
      name: 'opentalon',
      display_name: 'OpenTalon',
      icon: 'icon.png',
      version,
      description: 'Manage your local OpenTalon boards and tasks from Claude.',
      author: { name: 'Protomota', url: 'https://protomota.com' },
      server: {
        type: 'node',
        entry_point: 'mcp-extension.cjs',
        mcp_config: {
          command: 'node',
          args: ['${__dirname}/mcp-extension.cjs'],
          env: { OPENTALON_MCP_CONFIG: configFile },
        },
      },
      compatibility: { platforms: ['darwin'] },
    }
    await fs.writeFile(path.join(staging, 'manifest.json'), JSON.stringify(manifest, null, 2), {
      mode: 0o600,
    })
    await fs.copyFile(path.join(__dirname, 'mcp-bridge.cjs'), path.join(staging, 'mcp-bridge.cjs'))
    await fs.copyFile(
      path.join(__dirname, 'mcp-extension.cjs'),
      path.join(staging, 'mcp-extension.cjs')
    )
    await fs.copyFile(
      path.join(__dirname, '..', 'assets', 'opentalon-logo-1024.png'),
      path.join(staging, 'icon.png')
    )
    const archive = path.join(staging, 'OpenTalon.mcpb')
    await run(
      '/usr/bin/zip',
      ['-q', archive, 'manifest.json', 'mcp-extension.cjs', 'mcp-bridge.cjs', 'icon.png'],
      {
        cwd: staging,
      }
    )
    await fs.copyFile(archive, destination)
    return { path: destination }
  } finally {
    await fs.rm(staging, { recursive: true, force: true })
  }
}
function readProjectConfig(file) {
  try {
    const stat = fsSync.lstatSync(file)
    if (!stat.isFile() || stat.isSymbolicLink())
      throw new AppError(
        'INVALID_CONFIG',
        'Choose a folder with a regular .mcp.json file, not a link.'
      )
    return fsSync.readFileSync(file, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}
function prepareProjectSetup(folder, config) {
  const file = path.join(folder, '.mcp.json')
  const previous = readProjectConfig(file)
  let existing
  try {
    existing = previous === null ? {} : JSON.parse(previous)
  } catch {
    throw new AppError(
      'INVALID_CONFIG',
      'The existing .mcp.json is not valid JSON. OpenTalon has not changed it.'
    )
  }
  const object = (value) => value && typeof value === 'object' && !Array.isArray(value)
  if (!object(existing) || (existing.mcpServers !== undefined && !object(existing.mcpServers)))
    throw new AppError(
      'INVALID_CONFIG',
      'The existing .mcp.json needs an object containing mcpServers. OpenTalon has not changed it.'
    )
  const server = { type: 'stdio', ...config.mcpServers.opentalon }
  return {
    file,
    previous,
    replacing:
      existing.mcpServers?.opentalon !== undefined &&
      JSON.stringify(existing.mcpServers.opentalon) !== JSON.stringify(server),
    next:
      JSON.stringify(
        { ...existing, mcpServers: { ...existing.mcpServers, opentalon: server } },
        null,
        2
      ) + '\n',
  }
}
function writeProjectSetup(setup) {
  if (readProjectConfig(setup.file) !== setup.previous)
    throw new AppError(
      'CONFIG_CHANGED',
      'The project connection file changed. Try again; your changes were preserved.'
    )
  const temporary = path.join(path.dirname(setup.file), `.opentalon-mcp-${randomUUID()}.tmp`)
  try {
    fsSync.writeFileSync(temporary, setup.next, { flag: 'wx', mode: 0o600 })
    fsSync.renameSync(temporary, setup.file)
  } finally {
    if (fsSync.existsSync(temporary)) fsSync.unlinkSync(temporary)
  }
  return { file: setup.file }
}
module.exports = {
  setupFields,
  terminalCommand,
  saveClaudeExtension,
  prepareProjectSetup,
  writeProjectSetup,
}
