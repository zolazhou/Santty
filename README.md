# Santty

Santty is a macOS terminal emulator written in Swift. It is a native AppKit
wrapper around the Ghostty terminal core, consumed through the local
`libghostty-spm` Swift package.

## Requirements

- macOS 14.0 or later
- Xcode with the macOS SDK installed
- [mise](https://mise.jdx.dev/) for the pinned Tuist version
- Tuist 4.156.0, installed through `mise`
- Local Ghostty package fork at `../libghostty-spm`

The project currently depends on a local package:

```swift
.local(path: "../libghostty-spm")
```

Make sure the directory layout is:

```text
/
  Santty/
  libghostty-spm/
```

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

Build an archive:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/Santty.xcarchive \
  archive
```

Export the app from the archive:

```sh
mkdir -p build/export
cp -R build/Santty.xcarchive/Products/Applications/Santty.app build/export/
```

Create a distributable zip:

```sh
ditto -c -k --keepParent build/export/Santty.app build/Santty.zip
```

The packaged app will be:

```text
build/export/Santty.app
build/Santty.zip
```

## Publish an Update (Sparkle)

Santty uses [Sparkle](https://github.com/sparkle-project/Sparkle) for automatic
updates. The app reads its appcast from:

```text
https://github.com/zolazhou/Santty/releases/latest/download/appcast.xml
```

So every GitHub release must include both `Santty.zip` and `appcast.xml` as
assets.

### One-Time Key Setup

Build the project once so SwiftPM fetches the Sparkle artifacts, then locate
the Sparkle tools:

```sh
SPARKLE_BIN=$(echo ~/Library/Developer/Xcode/DerivedData/Santty-*/SourcePackages/artifacts/sparkle/Sparkle/bin)
```

Generate the EdDSA signing key (private key goes to the login keychain):

```sh
"$SPARKLE_BIN/generate_keys"
```

Copy the printed public key into `SUPublicEDKey` in `Project.swift`, then
regenerate the workspace.

### Release Steps

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Project.swift`
   (Sparkle compares `CFBundleVersion`), then regenerate:

   ```sh
   mise run tuist:generate
   ```

2. Archive, export, and zip as described in "Package a Local Release" above.

3. Generate the appcast (embeds the EdDSA signature from the keychain):

   ```sh
   "$SPARKLE_BIN/generate_appcast" build
   ```

   Move the resulting `appcast.xml` next to `Santty.zip`.

4. Create a GitHub release tagged with the version and upload both
   `Santty.zip` and `appcast.xml` as release assets.

Older builds pick up the update on their next scheduled check, or immediately
via Santty menu → Check for Updates....

## Signing Notes

Release builds are configured in `Project.swift` with:

- Bundle ID: `com.zolazhou.santty`
- Development Team: `75Y59WH38Q`
- Hardened Runtime: enabled
- Code signing style: automatic

If you build on another Apple Developer account, update the Release signing
settings in `Project.swift`, then regenerate the workspace:

```sh
mise run tuist:generate
```

## Local GhosttyKit Rebuild

Santty expects `../libghostty-spm/BinaryTarget/GhosttyKit.xcframework` to exist.
If the Ghostty binary target needs to be rebuilt, run the build script in the
local fork:

```sh
cd ../libghostty-spm
./build.sh --platforms macos --skip-tests
swift test
```

Then return to Santty and regenerate:

```sh
cd ../Santty
mise run tuist:generate
```

## Cleanup

Clean generated Tuist artifacts:

```sh
mise run tuist:clean
```

Clean local packaging output:

```sh
rm -rf build
```
