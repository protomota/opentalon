const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')
const { build } = require('../package.json')

// Restrict identity lookup so a System-keychain duplicate cannot trigger a
// separate administrator prompt for each of Electron's nested components.
const keychain = path.resolve(
  process.env.CSC_KEYCHAIN || path.join(os.homedir(), 'Library/Keychains/login.keychain-db')
)
const identity = process.env.CSC_NAME || build.mac.identity
if (
  process.platform !== 'darwin' ||
  !fs.existsSync(keychain) ||
  keychain === '/Library/Keychains/System.keychain'
) {
  console.error('Mac signing requires your login or a dedicated user signing keychain. See docs/SIGNING.md.')
  process.exit(1)
}

const identities = execFileSync('security', ['find-identity', '-v', '-p', 'codesigning', keychain], {
  encoding: 'utf8',
})
const name = `Developer ID Application: ${identity.replace(/^Developer ID Application: /, '')}`
if (!identities.split('\n').some((line) => line.trimEnd().endsWith(`"${name}"`))) {
  console.error(`The required Developer ID identity is missing from ${keychain}.`)
  console.error('Import the certificate AND private key into that keychain first. See docs/SIGNING.md.')
  process.exit(1)
}

const env = { ...process.env, CSC_KEYCHAIN: keychain, CSC_NAME: identity }
const run = (args) => {
  const result = spawnSync('npm', args, { env, stdio: 'inherit' })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status || 1)
}
run(['run', 'build'])
run([
  'exec',
  '--',
  'electron-builder',
  ...(process.argv.includes('--release') ? ['--config', 'electron-builder.release.cjs'] : []),
  '--mac',
  ...(process.argv.includes('--release') ? [] : ['dir']),
  '--publish',
  'never',
])
