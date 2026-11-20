<img src="assets/icon.svg" width="64" height="64" alt="">

# macstorage

A macOS app that shows where disk space goes on a developer Mac in more detail than System Settings. It breaks "System Data" and "Developer" down into what actually owns the space: container VM disks, the Nix store, Xcode and simulators, package-manager caches, piles of git worktrees. For each item it says how much you'd really get back and whether it's safe to remove.

- Native SwiftUI, no network access, no AI. Recommendations come from built-in rules.
- Uses each tool's own accounting (`docker system df`, `nix-store`, `xcrun simctl`, …) instead of naive `du`, and is APFS-aware (clones, sparse disk images, snapshots, purgeable space).
- Cleanup always shows exactly what it will delete before it deletes anything.

The design is in [docs/PLAN.md](docs/PLAN.md).

## Status

Early. The only thing that exists so far is the **M0 probe** (`spikes/m0-probe/`), a throwaway app that checks what is possible on a real (possibly MDM-managed) Mac: whether a downloaded self-signed app runs, whether Full Disk Access survives updates, how APFS reports clone and sparse-file sizes, and where each tool keeps its data. It produces an anonymized report.

### Trying the probe

1. In Terminal, download and install it in one go (replace the version with the latest from [Releases](../../releases)):
   ```sh
   v=0.1.0; curl -fsSL "https://github.com/OSMorph/macstorage/releases/download/probe-v$v/MacStorageProbe-$v.zip" -o /tmp/probe.zip \
     && rm -rf /Applications/MacStorageProbe.app && ditto -x -k /tmp/probe.zip /Applications && open /Applications/MacStorageProbe.app
   ```
2. That's needed because the app is self-signed, not notarized by Apple. A browser download gets a quarantine mark, and macOS then says "Apple could not verify…" and refuses to open it. `curl` doesn't add that mark. If you did download it in a browser, run `xattr -dr com.apple.quarantine /Applications/MacStorageProbe.app`, or click **Open Anyway** in System Settings → Privacy & Security.
3. Follow the three steps in the window.

It reads but doesn't change anything, apart from a small test folder in the temporary directory that it deletes again.

## A personal project

This is shared as is. Issues and discussions are turned off, and pull requests may never get looked at. Fork it if it's useful to you.
