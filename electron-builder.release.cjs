const base = require('./package.json').build

const hasNotaryCredentials = Boolean(
  (process.env.APPLE_API_KEY && process.env.APPLE_API_KEY_ID && process.env.APPLE_API_ISSUER) ||
    (process.env.APPLE_ID &&
      process.env.APPLE_APP_SPECIFIC_PASSWORD &&
      process.env.APPLE_TEAM_ID) ||
    process.env.APPLE_KEYCHAIN_PROFILE
)

if (!hasNotaryCredentials) {
  throw new Error('Configure Apple notarization credentials before release. See docs/SIGNING.md.')
}

module.exports = {
  ...base,
  forceCodeSigning: true,
  extraResources: [
    ...base.extraResources,
    { from: 'build/installer-background.tiff', to: 'installer-background.tiff' },
  ],
  afterSign: require('./build/package-installer.cjs'),
  directories: {
    ...base.directories,
    output: '/Volumes/Expand/Codex Media/opentalon/signed-release',
  },
  mac: {
    ...base.mac,
    identity: process.env.CSC_NAME || base.mac.identity,
    notarize: true,
    target: ['zip'],
  },
}
