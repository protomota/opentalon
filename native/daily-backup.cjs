const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')

const day = (date) =>
  [date.getFullYear(), date.getMonth() + 1, date.getDate()]
    .map((part, index) => String(part).padStart(index === 0 ? 4 : 2, '0'))
    .join('-')

class DailyBackup {
  constructor(store, { now = () => new Date(), changed = () => {} } = {}) {
    this.store = store
    this.now = now
    this.changed = changed
    this.file = path.join(store.folder, 'daily-backup.json')
    this.defaultFolder = path.join(store.folder, 'Backups', 'Daily')
    try {
      this.config = JSON.parse(fs.readFileSync(this.file, 'utf8'))
    } catch (error) {
      this.config = {}
      if (error.code !== 'ENOENT')
        this.configError = 'Could not read the daily backup settings. Review the folder and save your settings again.'
    }
  }

  status() {
    return {
      enabled: this.config.enabled !== false,
      folder: this.config.folder || this.defaultFolder,
      usesDefaultFolder: !this.config.folder,
      lastBackupAt: this.config.lastBackupAt || null,
      lastError: this.configError || this.config.lastError || '',
    }
  }

  persist() {
    const temp = path.join(this.store.folder, `.daily-${randomUUID()}.tmp`)
    try {
      fs.writeFileSync(temp, JSON.stringify(this.config) + '\n', { mode: 0o600, flag: 'wx' })
      fs.renameSync(temp, this.file)
    } finally {
      if (fs.existsSync(temp)) fs.unlinkSync(temp)
    }
    this.changed()
  }

  async configure(input) {
    if (this.running) await this.running.catch(() => {})
    if ('enabled' in input) this.config.enabled = input.enabled === true
    if ('folder' in input) {
      if (input.folder !== null &&
          (!path.isAbsolute(input.folder) || !fs.statSync(input.folder).isDirectory()))
        throw new Error('Choose an existing backup folder.')
      this.config.folder = input.folder
      this.config.lastBackupAt = null
    }
    this.configError = ''
    this.config.lastError = ''
    this.persist()
    return this.status()
  }

  run({ force = false } = {}) {
    if (this.running) return force
      ? this.running.catch(() => {}).then(() => this.run({ force: true }))
      : this.running
    this.running = this.backUp(force).finally(() => { this.running = null })
    return this.running
  }

  async backUp(force) {
    const settings = this.status()
    if (!force && (!settings.enabled || this.configError)) return settings
    const date = this.now()
    const file = path.join(settings.folder,
      force ? `OpenTalon-${day(date)}-${randomUUID().slice(0, 8)}.json` : `OpenTalon-${day(date)}.json`)
    let staging
    try {
      if (settings.usesDefaultFolder) fs.mkdirSync(settings.folder, { recursive: true, mode: 0o700 })
      if (fs.existsSync(file)) return settings
      // Stage under the destination so publishing stays on the same volume. The
      // shared store writes a complete JSON export before a daily file is visible.
      staging = fs.mkdtempSync(path.join(settings.folder, '.opentalon-backup-'))
      const destination = path.join(staging, 'snapshot.json')
      await this.store.dispatch('create_backup', { destination, format: 'json', requestKey: randomUUID() })
      try {
        fs.linkSync(destination, file)
      } catch (error) {
        if (error.code === 'EEXIST') return settings
        if (!['ENOTSUP', 'EOPNOTSUPP', 'EPERM'].includes(error.code)) throw error
        // Some removable filesystems do not support hard links.
        fs.copyFileSync(destination, file, fs.constants.COPYFILE_EXCL)
        fs.chmodSync(file, 0o600)
      }
      this.config.lastBackupAt = date.toISOString()
      this.config.lastError = ''
      this.persist()
    } catch (error) {
      const message = ['ENOENT', 'ENOTDIR'].includes(error.code)
        ? 'The backup folder is unavailable. Reconnect its drive or choose another folder.'
        : 'Could not save the backup. Check the folder’s permissions and available space.'
      if (this.config.lastError !== message) {
        this.config.lastError = message
        this.persist()
      }
      if (force) throw new Error(message)
    } finally {
      if (staging) fs.rmSync(staging, { recursive: true, force: true })
    }
    return this.status()
  }
}

module.exports = { DailyBackup }
