// launchd's short-lived backup mode does not start MCP or run agents.
const fs = require('node:fs')
const path = require('node:path')
const { Store } = require('./store.cjs')
const { DailyBackup } = require('./daily-backup.cjs')

async function main() {
  const folder = process.argv[2]
  if (!path.isAbsolute(folder) || !fs.existsSync(path.join(folder, 'opentalon.sqlite'))) return
  const store = new Store(folder)
  try {
    await new DailyBackup(store).run()
  } finally {
    store.close()
  }
}

main().catch((error) => {
  console.error('OpenTalon daily backup:', error.message)
  process.exitCode = 1
})
