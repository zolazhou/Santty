# Santty

Santty is a macOS terminal emulator written in Swift. It is a native AppKit
wrapper around the Ghostty terminal core, consumed through the
[`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) Swift package.

## Requirements

- macOS 14.0 or later
- Xcode with the macOS SDK installed
- [mise](https://mise.jdx.dev/) for the pinned Tuist version
- Tuist 4.156.0, installed through `mise`

## Generate the Xcode Workspace

Install Tuist dependencies and generate the workspace:

```sh
mise run tuist:install
mise run tuist:generate
```

For a full regenerate:

```sh
mise run tuist:regen
```

Generated Xcode files are intentionally not committed.

## Build

Open `Santty.xcworkspace` in Xcode and build the `Santty` scheme, or build from
the command line:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

For Release:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

The app bundle is written under Xcode DerivedData, for example:

```text
~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Santty.app
~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/Santty.app
```

## Test

Run the unit tests:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

## Package a Local Release

Run the full pipeline (archive → Developer ID export → notarize → zip → appcast):

```sh
mise run release:package
```

This requires a "Developer ID Application" certificate in the login keychain,
`TUIST_SANTTY_DEVELOPMENT_TEAM` set in `mise.local.toml` (see "Signing
Notes"), and configured `asc` credentials (used for notarization via Apple's
Notary API).

Or run the steps individually:

```sh
# Build an archive
mise run release:archive

# Export the app from the archive, signed with Developer ID
mise run release:export

# Notarize the app with Apple and staple the ticket
mise run release:notarize

# Create a distributable zip from the notarized app
mise run release:zip

# Generate the Sparkle appcast
mise run sparkle:generate-appcast
```

The packaged artifacts will be:

```text
build/export/Santty.app
build/Santty.zip
build/appcast.xml
```

## Publish an Update (Sparkle)

Santty uses [Sparkle](https://github.com/sparkle-project/Sparkle) for automatic
updates. Sparkle is only compiled in when two environment variables are set at
`tuist generate` time (typically via `mise.local.toml`, see "Signing Notes"):

- `TUIST_SANTTY_SPARKLE_FEED_URL` — the appcast URL the app polls
- `TUIST_SANTTY_SPARKLE_PUBLIC_KEY` — the EdDSA public key (`SUPublicEDKey`)

Without them the built app ships without any Sparkle keys: the updater never
starts and the update UI (menu item, settings pane section) is hidden. Forks
that want updates must point these at their own appcast and key pair.

The official builds read their appcast from:

```text
https://github.com/zolazhou/Santty/releases/latest/download/appcast.xml
```

So every GitHub release must include both `Santty.zip` and `appcast.xml` as
assets.

### One-Time Key Setup

Build the project once so SwiftPM fetches the Sparkle artifacts. `mise.toml`
then sets `SPARKLE_BIN` to the Sparkle tools directory (available via
`mise activate`, `mise run`, and `mise x`).

Generate the EdDSA signing key (private key goes to the login keychain):

```sh
mise run sparkle:generate-keys
```

Put the printed public key into `TUIST_SANTTY_SPARKLE_PUBLIC_KEY` in
`mise.local.toml`, then regenerate the workspace.

### Release Steps

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Project.swift`
   (Sparkle compares `CFBundleVersion`), then regenerate:

   ```sh
   mise run tuist:generate
   ```

2. Publish the release (requires the authenticated [GitHub CLI](https://cli.github.com/)):

   ```sh
   mise run release:publish
   ```

   This runs the full packaging pipeline from "Package a Local Release" above
   (archive, Developer ID export, notarization, zip, `build/appcast.xml` with
   the EdDSA signature from the keychain), then creates a GitHub release
   tagged `v<CFBundleShortVersionString>` with `Santty.zip` and `appcast.xml`
   as assets and auto-generated notes.

Older builds pick up the update on their next scheduled check, or immediately
via Santty menu → Check for Updates....

## Signing Notes

The repo carries no private signing values. `Project.swift` reads two
environment variables at `tuist generate` time (note: Tuist only forwards
`TUIST_*` variables to manifests):

- `TUIST_SANTTY_DEVELOPMENT_TEAM` — Apple Development Team ID
- `TUIST_SANTTY_BUNDLE_IDENTIFIER` — base bundle ID (Debug appends `.dev`)

Without them you get a locally-signed (adhoc) build with the placeholder
bundle ID `dev.santty.local` — enough to build and run the app.

To use your own Apple Developer account, create `mise.local.toml`
(gitignored, loaded automatically by mise):

```toml
[env]
TUIST_SANTTY_DEVELOPMENT_TEAM = "YOUR_TEAM_ID"
TUIST_SANTTY_BUNDLE_IDENTIFIER = "com.yourdomain.santty"
```

Then regenerate the workspace:

```sh
mise run tuist:generate
```

The maintainer's Release builds additionally enable Hardened Runtime and use
automatic signing with the "Apple Development" identity; the `release:*`
mise tasks export with the "Developer ID Application" certificate and
notarize via `asc` (see "Package a Local Release").

## Cleanup

Clean generated Tuist artifacts:

```sh
mise run tuist:clean
```

Clean local packaging output:

```sh
rm -rf build
```
