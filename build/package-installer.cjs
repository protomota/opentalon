const path = require('node:path')
const fs = require('node:fs')
const { execFileSync } = require('node:child_process')
const { Arch } = require('builder-util')

module.exports = function packageInstaller({ appOutDir, outDir, arch, packager }) {
  const { productFilename, version } = packager.appInfo
  const title = productFilename.replace(/ Prototype$/, '')
  const app = path.join(appOutDir, `${productFilename}.app`)
  const name = `${title}-${version}-${Arch[arch]}`
  const temporary = fs.mkdtempSync(path.join(outDir, '.installer-'))
  try {
    execFileSync(
      process.env.DMG_PYTHON || 'python3',
      [path.join(__dirname, 'package-installer.py'), app, path.join(temporary, `${name}.dmg`), title],
      { stdio: 'inherit' }
    )
    for (const extension of ['.dmg', '.notarization.json']) {
      const file = name + extension
      fs.renameSync(path.join(temporary, file), path.join(outDir, file))
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}
