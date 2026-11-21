<img src="assets/icon.svg" width="64" height="64" alt="">

# macstorage

A macOS app that shows where disk space goes on a developer Mac in more detail than System Settings. It breaks "System Data" and "Developer" down into what actually owns the space: container VM disks, the Nix store, Xcode and simulators, package-manager caches, piles of git worktrees. For each item it says how much you'd really get back and whether it's safe to remove.

- Native SwiftUI, no network access, no AI. Recommendations come from built-in rules.
- Uses each tool's own accounting (`docker system df`, `nix-store`, `xcrun simctl`, …) instead of naive `du`, and is APFS-aware (clones, sparse disk images, snapshots, purgeable space).
- Cleanup always shows exactly what it will delete before it deletes anything.

The design is in [docs/PLAN.md](docs/PLAN.md).

## Install

1. In Terminal, download and install it in one go (replace the version with the latest from [Releases](../../releases)):
   ```sh
   v=0.1.1; curl -fsSL "https://github.com/OSMorph/macstorage/releases/download/v$v/MacStorage-$v.zip" -o /tmp/macstorage.zip \
     && rm -rf /Applications/MacStorage.app && ditto -x -k /tmp/macstorage.zip /Applications && open /Applications/MacStorage.app
   ```
   The app is self-signed, not notarized by Apple. A browser download gets a quarantine mark, and macOS then says "Apple could not verify…" and won't open it. `curl` doesn't add that mark. If you did download it in a browser, run `xattr -dr com.apple.quarantine /Applications/MacStorage.app`, or click **Open Anyway** in System Settings → Privacy & Security.
2. In the app, follow the welcome screen: give it Full Disk Access (recommended), then scan.
3. To update, run the same command with the new version. Full Disk Access should stay granted, because every release is signed with the same certificate (not yet confirmed across an update).

Nothing is deleted until you've reviewed a cleanup preview. Personal files only ever go to the Trash, one by one. Every cleanup is recorded in History with a receipt.

To try it without touching anything, launch it with sample data: `open /Applications/MacStorage.app --args --demo`.

## Status

Early (0.x). The scan, recommendations, cleanup and history work; see [docs/PLAN.md](docs/PLAN.md) for what's planned. The `spikes/m0-probe/` folder holds the throwaway probe that checked what's possible on a managed Mac; its releases are tagged `probe-v*`.

## A personal project

This is shared as is. Issues and discussions are turned off, and pull requests may never get looked at. Fork it if it's useful to you.
