---
sidebar_position: 6
title: Changelog
description: Release notes for every ClipSlop version. Updates ship via Sparkle's appcast.
---

# Changelog

ClipSlop ships releases through [GitHub Releases](https://github.com/mekedron/ClipSlop/releases). Each release has its own notes — what's new, what's fixed, what's breaking.

## Where to find release notes

- **Inside the app** — Sparkle (the macOS update framework) shows the release notes when an update is available. Click **Install** or skip; the appcast is fetched from this repo.
- **On GitHub** — [github.com/mekedron/ClipSlop/releases](https://github.com/mekedron/ClipSlop/releases). The full archive, oldest at the bottom.

## How updates work

ClipSlop uses [Sparkle](https://sparkle-project.org), the standard macOS update framework. The app periodically fetches `appcast.xml` from this repo and prompts you when a new version is available. You're always free to skip an update — there's no forced upgrade.

After updating, you may need to re-grant Accessibility / Screen Recording — see [Install & first run → After updating](../install.mdx#after-updating-to-a-new-version) and [Troubleshooting](./troubleshooting.md).

## Subscribing without auto-update

If you'd rather check manually, watch the [Releases page](https://github.com/mekedron/ClipSlop/releases) on GitHub or subscribe to its Atom feed:

```
https://github.com/mekedron/ClipSlop/releases.atom
```
