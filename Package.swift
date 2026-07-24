// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipSlop",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0"),
        .package(url: "https://github.com/Infomaniak/swift-rich-html-editor.git", from: "3.0.0"),
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClipSlop",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Textual", package: "textual"),
                .product(name: "InfomaniakRichHTMLEditor", package: "swift-rich-html-editor"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            ],
            path: "Sources",
            resources: [
                // `.process` flattens subdirectories (and SwiftPM rejects a
                // nested override rule inside `Resources`), so the agent
                // skill lives beside it and keeps its directory shape
                // (SKILL.md + references/) via an explicit `.copy` rule.
                .copy("AgentSkill/clipslop"),
                .process("Resources"),
            ],
            swiftSettings: [
                // App Intents metadata extraction. Xcode normally injects these
                // via its own build system; SwiftPM does not, so `Metadata.appintents`
                // would silently never be produced and no intent would exist at
                // runtime. `Scripts/generate-appintents-metadata.sh` consumes the
                // emitted .swiftconstvalues files.
                //
                // The protocol list ships in-repo rather than being read from the
                // toolchain: Xcode's own copy is wrapped in a dict the Swift frontend
                // rejects as malformed, and its path differs across Xcode/Xcode-beta/CI.
                // The relative path resolves against the package root, same as the
                // SupportingFiles/Info.plist linker flag below.
                .unsafeFlags([
                    "-Xfrontend", "-const-gather-protocols-file",
                    "-Xfrontend", "SupportingFiles/AppIntentsConstValueProtocols.json",
                    "-emit-const-values",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "SupportingFiles/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "ClipSlopTests",
            dependencies: ["ClipSlop"],
            path: "Tests"
        )
    ]
)
