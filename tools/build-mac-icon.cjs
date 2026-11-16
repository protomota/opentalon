// Regenerate the committed macOS icon using the same native iconset/.icns route as Inkspring.
// Requires macOS (sips/iconutil) and ImageMagick. Build caches and intermediate images stay on Expand.
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const root = path.resolve(__dirname, '..')
const work = '/Volumes/Expand/Codex Media/opentalon/prototype/icon-build'
if (!fs.existsSync('/Volumes/Expand')) throw new Error('Mount Expand before generating app icons.')
fs.mkdirSync(work, { recursive: true })
const master = path.join(work, 'opentalon-app-icon.png')
execFileSync('magick', [
  path.join(root, 'assets/opentalon-logo-1024.png'),
  '-resize',
  '824x824',
  '(',
  '-size',
  '824x824',
  'xc:black',
  '-fill',
  'white',
  '-draw',
  'roundrectangle 0,0 823,823 185,185',
  ')',
  '-alpha',
  'off',
  '-compose',
  'CopyOpacity',
  '-composite',
  '-compose',
  'Over',
  '-background',
  'none',
  '-gravity',
  'center',
  '-extent',
  '1024x1024',
  master,
])
const iconset = path.join(work, 'OpenTalon.iconset')
fs.mkdirSync(iconset, { recursive: true })
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const file = path.join(iconset, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`)
    execFileSync(
      '/usr/bin/sips',
      ['-z', String(size * scale), String(size * scale), master, '--out', file],
      { stdio: 'ignore' }
    )
  }
}
const output = path.join(work, 'opentalon.icns')
execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', output])
fs.copyFileSync(output, path.join(root, 'assets/opentalon.icns'))
console.log('Created assets/opentalon.icns; intermediate iconset is on Expand.')
