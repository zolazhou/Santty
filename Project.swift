import ProjectDescription

let project = Project(
    name: "Santty",
    options: .options(
        automaticSchemesOptions: .enabled(
            targetSchemesGrouping: .singleScheme,
            testingOptions: []
        )
    ),
    packages: [
        .local(path: "../libghostty-spm"),
        .remote(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            requirement: .upToNextMajor(from: "2.4.0")
        ),
        .remote(
            url: "https://github.com/sparkle-project/Sparkle",
            requirement: .upToNextMajor(from: "2.8.0")
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
            infoPlist: .extendingDefault(
                with: [
                    "NSPrincipalClass": "NSApplication",
                    "LSApplicationCategoryType": "public.app-category.productivity",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "SUFeedURL":
                        "https://github.com/zolazhou/Santty/releases/latest/download/appcast.xml",
                    "SUPublicEDKey": "oYg1ZPw6unC7mAUjSR3ELWRWIYjoq5VJnv49KkykXZs=",
                    "SUEnableAutomaticChecks": true,
                ]
            ),
            sources: ["Santty/Sources/**"],
            resources: ["Santty/Resources/**"],
            dependencies: [
                .package(product: "GhosttyTheme"),
                .package(product: "GhosttyTerminal"),
                .package(product: "KeyboardShortcuts"),
                .package(product: "Sparkle"),
                .sdk(name: "AppKit", type: .framework),
                .sdk(name: "CoreGraphics", type: .framework),
                .sdk(name: "CoreText", type: .framework),
                .sdk(name: "QuartzCore", type: .framework),
                .sdk(name: "Metal", type: .framework),
                .sdk(name: "MetalKit", type: .framework),
                .sdk(name: "IOKit", type: .framework),
                .sdk(name: "Carbon", type: .framework),
                .sdk(name: "UserNotifications", type: .framework),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "$(SANTTY_APP_ICON_NAME)",
                ],
                configurations: [
                    .debug(
                        name: "Debug",
                        settings: [
                            "SANTTY_APP_ICON_NAME": "AppIconDev",
                            "SANTTY_BUNDLE_IDENTIFIER": "com.zolazhou.santty.dev",
                        ]
                    ),
                    .release(
                        name: "Release",
                        settings: [
                            "CODE_SIGN_IDENTITY": "Apple Development",
                            "CODE_SIGN_STYLE": "Automatic",
                            "DEVELOPMENT_TEAM": "75Y59WH38Q",
                            "ENABLE_HARDENED_RUNTIME": "YES",
                            "PROVISIONING_PROFILE_SPECIFIER": "",
                            "SANTTY_APP_ICON_NAME": "AppIcon",
                            "SANTTY_BUNDLE_IDENTIFIER": "com.zolazhou.santty",
                        ]
                    ),
                ]
            )
        ),
        .target(
            name: "SanttyTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.zolazhou.santty.tests",
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
