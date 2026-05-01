---
sidebar_position: 1
title: Build from source
---

# Build from source

```bash
git clone https://github.com/mekedron/ClipSlop.git
cd ClipSlop
swift build
```

Or open `Package.swift` in Xcode and **Run**.

## Requirements

- macOS 14.0+
- Xcode with Swift 6.0+

## Project layout

```
Sources/
├── App/          SwiftUI entry point and menu-bar wiring
├── Models/       Domain types (prompts, providers, transformations)
├── Services/     Provider clients, OAuth, OCR, keyboard hooks
├── Views/        UI surfaces — main panel, settings, prompt picker
├── Utilities/    Cross-cutting helpers
└── Resources/    Assets, localisable strings
Tests/            XCTest suite mirroring Sources/ structure
```

## Running the test suite

```bash
swift test
```

## Release builds

The macOS release pipeline (`.github/workflows/release.yml`) is fully automated:

1. Triggered by pushing a `v*.*.*` tag.
2. Builds a universal binary (arm64 + x86_64).
3. Codesigns and notarises (if secrets are configured).
4. Produces a DMG and updates `appcast.xml` for in-app Sparkle updates.
5. Updates the Homebrew cask.

To cut a release locally, see `Scripts/`.

## Contributing

Open an issue or PR on [github.com/mekedron/ClipSlop](https://github.com/mekedron/ClipSlop). The codebase is small enough that a tour of `Sources/` and `Tests/` is the fastest way in.
