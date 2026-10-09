import Foundation
import ProjectDescription

// Signing and bundle identity come from the environment so the repo carries no
// private values. Tuist only forwards TUIST_* variables to manifests; the
// maintainer sets them in `mise.local.toml` (gitignored). Contributors need
// nothing and get a locally-signed build with a placeholder bundle ID.
let environment = ProcessInfo.processInfo.environment
let developmentTeam = environment["TUIST_SANTTY_DEVELOPMENT_TEAM"] ?? ""
let bundleIdentifier = environment["TUIST_SANTTY_BUNDLE_IDENTIFIER"] ?? "dev.santty.local"
let sparkleFeedURL = environment["TUIST_SANTTY_SPARKLE_FEED_URL"] ?? ""
let sparklePublicKey = environment["TUIST_SANTTY_SPARKLE_PUBLIC_KEY"] ?? ""

// Sparkle keys are only embedded when configured; without a feed URL the
// updater stays disabled (see AppUpdater.swift).
var infoPlistEntries: [String: Plist.Value] = [
    "NSPrincipalClass": "NSApplication",
    "LSApplicationCategoryType": "public.app-category.productivity",
    "CFBundleShortVersionString": "1.2.1",
    "CFBundleVersion": "4",
    "NSAppTransportSecurity": [
        "NSAllowsArbitraryLoadsInWebContent": true
    ],
]
if !sparkleFeedURL.isEmpty, !sparklePublicKey.isEmpty {
    infoPlistEntries["SUFeedURL"] = .string(sparkleFeedURL)
    infoPlistEntries["SUPublicEDKey"] = .string(sparklePublicKey)
    infoPlistEntries["SUEnableAutomaticChecks"] = true
}

let signingSettings: SettingsDictionary =
    developmentTeam.isEmpty
    ? [
        "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Manual",
    ]
    : [
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": .string(developmentTeam),
        "PROVISIONING_PROFILE_SPECIFIER": "",
    ]

let project = Project(
    name: "Santty",
    options: .options(
        automaticSchemesOptions: .enabled(
            targetSchemesGrouping: .singleScheme,
            testingOptions: []
        )
    ),
    packages: [
        // Prepared by `mise run ghostty:prepare`: pinned upstream Swift source
        // plus text/selection bridges. The C core is still a binary dependency.
        .local(path: "Vendor/libghostty-spm"),
        .remote(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            requirement: .upToNextMajor(from: "3.1.0")
        ),
        .remote(
            url: "https://github.com/sparkle-project/Sparkle",
            requirement: .upToNextMajor(from: "2.8.0")
        ),
        .remote(
            url: "https://github.com/swiftlang/swift-markdown",
            requirement: .exact("0.9.0")
        ),
    ],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
        ]
    ),
    targets: [
        .target(
            name: "Santty",
            destinations: .macOS,
            product: .app,
            bundleId: "$(SANTTY_BUNDLE_IDENTIFIER)",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: infoPlistEntries),
            sources: ["Santty/Sources/**", "Santty/Shared/**"],
            resources: [
                .glob(pattern: "Santty/Resources/**", excluding: ["Santty/Resources/Skills/**"]),
                .folderReference(path: "Santty/Resources/Skills"),
            ],
            scripts: [
                .post(
                    script: """
                    set -eu
                    mkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
                    /usr/bin/ditto "$BUILT_PRODUCTS_DIR/santty" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/santty"
                    """,
                    name: "Embed Santty CLI",
                    inputPaths: ["$(BUILT_PRODUCTS_DIR)/santty"],
                    outputPaths: ["$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/santty"]
                )
            ],
            dependencies: [
                .target(name: "SanttyCLI"),
                .package(product: "GhosttyTheme"),
                .package(product: "GhosttyTerminal"),
                .package(product: "KeyboardShortcuts"),
                .package(product: "Sparkle"),
                .package(product: "Markdown"),
                .sdk(name: "AppKit", type: .framework),
                .sdk(name: "CoreGraphics", type: .framework),
                .sdk(name: "CoreText", type: .framework),
                .sdk(name: "QuartzCore", type: .framework),
                .sdk(name: "WebKit", type: .framework),
                .sdk(name: "Metal", type: .framework),
                .sdk(name: "MetalKit", type: .framework),
                .sdk(name: "IOKit", type: .framework),
                .sdk(name: "Carbon", type: .framework),
                .sdk(name: "UserNotifications", type: .framework),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "$(SANTTY_APP_ICON_NAME)"
                ],
                configurations: [
                    .debug(
                        name: "Debug",
                        settings: signingSettings.merging([
                            "SANTTY_APP_ICON_NAME": "AppIconDev",
                            "SANTTY_BUNDLE_IDENTIFIER": "\(bundleIdentifier).dev",
                        ]) { _, new in new }
                    ),
                    .release(
                        name: "Release",
                        settings: signingSettings.merging([
                            "ENABLE_HARDENED_RUNTIME": "YES",
                            "SANTTY_APP_ICON_NAME": "AppIcon",
                            "SANTTY_BUNDLE_IDENTIFIER": .string(bundleIdentifier),
                        ]) { _, new in new }
                    ),
                ]
            )
        ),
        .target(
            name: "SanttyCLI",
            destinations: .macOS,
            product: .commandLineTool,
            productName: "santty",
            bundleId: "\(bundleIdentifier).cli",
            deploymentTargets: .macOS("14.0"),
            infoPlist: nil,
            sources: ["SanttyCLI/**", "Santty/Shared/**"],
            settings: .settings(base: signingSettings.merging([
                "PRODUCT_MODULE_NAME": "SanttyCLI",
                "SKIP_INSTALL": "YES",
                "ENABLE_HARDENED_RUNTIME": "YES",
            ]) { _, new in new })
        ),
        .target(
            name: "SanttyTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundleIdentifier).tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Santty/Tests/**"],
            dependencies: [
                .target(name: "Santty"),
                .package(product: "GhosttyTheme"),
                .package(product: "GhosttyTerminal"),
                .package(product: "KeyboardShortcuts"),
            ]
        ),
    ]
)
