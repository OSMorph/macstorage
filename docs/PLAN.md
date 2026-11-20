# macstorage: plan

Status: **M0 done on an unmanaged Mac; next is the UI/UX design.** Checking the release on a managed (MDM) Mac is deferred until the app is worth installing there. Personal project, shared publicly with no support commitment (see "Repository").

## Goal

A native macOS app for developer Macs that answers "where did my disk go?" in more detail than System Settings, which lumps most of it into "System Data" and "Developer". It shows who owns each chunk of space (which tool, which project), how much you would really get back, and whether it's safe to remove. It can then clean up, after showing exactly what it will delete.

No LLM or network calls at runtime. All recommendations come from built-in rules.

## Decisions

| Topic | Decision |
|---|---|
| Form | Native SwiftUI window app. No CLI product. Menu-bar extra maybe later. |
| Primary view | Grouped by who owns the space (tool or project), with a folder view as a second tab. |
| Sizes | Each tool's own accounting where it exists. Filesystem numbers made APFS-aware. Always show "on disk" next to "reclaimable". |
| Recommendations | Rule-based, in four tiers (below). Every item shows the reason and the exact command or action. |
| Cleanup | Built in (milestone 5). It always shows a preview that lists every item and command before anything runs. Files go to the Trash, tools clean up through their own commands. Nothing is off-limits beyond what the tiers say. |
| History | Store every scan. Show what grew, how fast, and what keeps coming back. |
| Target | Developer Macs on a current macOS release, including MDM-managed ones. Not the App Store, not sandboxed. Minimum macOS 15. |
| Distribution | GitHub Actions builds the app on a macOS runner and publishes it to GitHub Releases, where it's downloaded from. Signing: option A (self-signed) first, option B (Developer ID + notarization) only if A is blocked. |
| Tools to support first | Docker Desktop, OrbStack, podman machine, colima, Nix, Xcode + simulators, Homebrew, Go, Node (npm/pnpm/yarn/bun/volta), Python (pip/uv), Rust (cargo/rustup), JVM (Gradle/Maven), CocoaPods. |

## Managed Macs and signing

The app is installed by downloading it from GitHub Releases, and it has to work on MDM-managed Macs. Two consequences:

- **Gatekeeper.** A downloaded app is marked as quarantined. macOS opens it normally only if it's signed with an Apple **Developer ID** and **notarized** by Apple, which needs the paid Apple Developer Program ($99/year). Without that, macOS refuses to open it until the quarantine mark is removed, either with "Open Anyway" in System Settings → Privacy & Security, if MDM allows it, or with `xattr -dr com.apple.quarantine <app>` after each download.
- **Full Disk Access.** macOS ties this permission to the app's signature. If CI signs ad hoc, every new version looks like a different app and Full Disk Access has to be granted again. Releases are therefore signed with **the same certificate every time**, stored as a CI secret.

| | A. Free: self-signed | B. Paid: Developer ID + notarization |
|---|---|---|
| Cost | $0 | $99/year Apple Developer Program |
| First launch of each download | One `xattr` command, or "Open Anyway" | Just opens |
| Full Disk Access survives updates | Expected (same certificate). *Verified in M0.* | Yes |
| Risk on a managed Mac | MDM or a security agent may block apps that aren't notarized | Lowest. An allowlist that only trusts certain developers could still block it. |

Option A comes first. If it's blocked, or the per-update step gets annoying, switch to B. Only the CI signing step changes. If both are blocked, the fallback is building on the Mac itself with Xcode, since a locally built app isn't quarantined.

Other constraints:
- **Full Disk Access may be locked by MDM.** The app still works with reduced coverage: it says which areas it couldn't read (Mail, Messages, Safari, other apps' containers, Time Machine) and doesn't guess. Without Full Disk Access, scanning Desktop, Documents, Downloads or other apps' containers triggers a series of macOS consent prompts, so those areas are skipped until access is granted.
- **No admin rights at runtime.** The app never runs as root. Actions that need admin (for example deleting local Time Machine snapshots) are shown as commands to paste into Terminal.
- **GUI apps don't get the shell's PATH.** Tools installed by Homebrew, Nix, OrbStack, volta, cargo and so on have to be located explicitly. `/usr/bin/git`, `python3`, `pip3` and `xcrun` are stubs that pop up an installer when the Command Line Tools are missing, so the app checks `xcode-select -p` before calling them.

## Architecture

One repository with three layers:

1. **`StorageCore`**, a Swift package of pure logic. It holds the data model (items, owners, tiers), the parsers for each tool's output, the recommendation rules, the size math (combining overlapping numbers), snapshot diffing and growth analysis, and cleanup-plan building. It has no macOS-only APIs, so it **builds and tests on Linux** against anonymized output fixtures captured on a real Mac.
2. **`StorageMac`**, a macOS-only package. It walks the filesystem with APFS-aware sizing, queries volumes and snapshots, locates and runs tool commands (fixed argument lists, no shell, timeouts), moves files to the Trash, and holds the SQLite history store.
3. **`MacStorage.app`**, the SwiftUI interface. The Xcode project is generated from a `project.yml` by XcodeGen, so the project file is plain text and editable without a Mac.

Data stays local in `~/Library/Application Support/macstorage/`. The app makes no network requests.

## How sizes are measured

Each item carries two numbers: **on disk** (what the filesystem allocates) and **reclaimable** (what you'd actually get back), plus a confidence level (exact, estimate, or unknown) and a note when the two disagree.

**Filesystem walk**
- Fast enumeration (`getattrlistbulk`/fts) using the allocated size, not the logical size. Sparse VM disks look huge by logical size.
- Hard links are counted once per inode.
- APFS clones: the private (non-shared) size attribute (`ATTR_CMNEXT_PRIVATESIZE`) keeps cloned copies (worktrees, Xcode, `cp -c`) from counting twice. *Verified in M0.* Without it, clone-heavy folders get an "estimate" confidence.
- The walk doesn't follow symlinks and doesn't leave the Data volume. Tool-owned areas such as `/nix/store` and VM disk images aren't walked file by file. Their tool provides the numbers.

**Volume level**
- Container and volume layout: the sealed system volume vs the Data volume, plus the Nix, Preboot and VM volumes.
- Free space as reported vs "available for important use", with the difference shown as purgeable.
- Local snapshots (`tmutil listlocalsnapshots`, `diskutil apfs listSnapshots`) shown as their own bucket, because space they hold doesn't appear in any folder.
- An "Unexplained" bucket for space used minus space attributed, so the gap is visible instead of hidden.

**What each tool reports.** The paths and commands below are expectations. M0 checks each one on a real Mac before it's relied on.

| Owner | What it counts | Source |
|---|---|---|
| Docker Desktop | VM disk size (`Docker.raw`, allocated) vs images, containers, volumes and build cache inside it | `docker system df -v` (desktop context) |
| OrbStack | Its data image vs what's inside | `docker system df` (orbstack context) |
| podman machine | Each machine's disk vs what's inside it, untagged images, images no container uses | `podman machine list/inspect`, `podman system df -v`, `podman images` |
| colima | Each profile's disk vs what's inside | `colima list`, docker context per profile |
| Nix | Store volume total, dead paths, old profile generations (user, home-manager, nix-darwin) | `statfs /nix`, `nix-store --gc --print-dead` + `nix path-info -S`, list generations |
| Xcode | DerivedData per project (read from each folder's `info.plist`), Archives, iOS DeviceSupport per OS version, simulator devices and runtimes, unavailable simulators | file walk, `xcrun simctl list -j`, `xcrun simctl runtime list -j` |
| Homebrew | Download cache, old versions | `brew --cache`, `brew cleanup -n` (dry run) |
| Language caches | Go build/module cache, npm, pnpm store, yarn, bun, volta, pip, uv, cargo registry, rustup toolchains, Gradle, Maven, CocoaPods | Ask each tool for its cache dir (`go env`, `npm config get cache`, `uv cache dir`, …), then walk it |
| Git checkouts | Repos found automatically anywhere in the home folder (skipping `~/Library`), with extra folders configurable, grouped by origin plus root commit, so dozens of dated worktrees of one repo show up together. Per copy: size, build output (`node_modules`, `target`, `.build`, `dist`), last commit, and whether it has uncommitted or unpushed work | file walk + `git` |
| Personal | Downloads, Desktop, iOS backups, Mail, Messages attachments, Photos, Trash | file walk |
| System and apps | `~/Library/Caches`, logs, crash reports, app support, by app | file walk |

**Container engines that aren't running.** The app doesn't start them on its own. It shows the VM disk's allocated size with "start the engine to see inside" and a button to do it. Several engines installed side by side is itself a finding: each has its own VM disk, probably holding copies of the same images.

**VM disks don't shrink on their own.** Pruning inside the VM frees space inside the VM, not on the Mac. Each engine gets a rule that explains how to actually get the space back (compact, reclaim or recreate the disk, depending on the engine; *details verified per engine in M0*), and the preview says so plainly.

## Recommendation tiers

| Tier | Meaning | Examples | Cleanup allowed? |
|---|---|---|---|
| **Safe** | Rebuilds itself automatically | Go build cache, npm/pip/uv caches, untagged container images, Nix dead paths, DerivedData, unavailable simulators, `brew cleanup` | Yes |
| **Probably safe** | Stale or rebuildable with effort | Tagged images not used for N days, old toolchains or simulator runtimes, DeviceSupport for iOS versions no longer used, `node_modules` in inactive checkouts, clean and fully pushed old worktrees, old Nix generations | Yes, unticked by default |
| **Review** | Holds unique data | Worktrees with uncommitted or unpushed work, Downloads, iOS backups, Archives, container volumes, Mail and Messages attachments | Only per item, with an extra confirmation, and only to the Trash |
| **Leave alone** | System-owned or in use | Sealed system volume, running containers, images used by containers, current Nix generation, booted simulators | No |

Every item shows the rule that matched, why, how it gets rebuilt if that's relevant, and the exact command or action. Rules are data (a table in `StorageCore`), so they can be unit-tested and tuned without UI changes. Thresholds such as "old" and "inactive" are settings.

## The interface

- **Overview:** disk bar (used, free, purgeable, snapshots), the largest owners ranked with their on-disk and reclaimable numbers, "changes since last scan", and the reclaimable total split by tier.
- **By owner** (main view): a treemap of owners, then items, next to a sortable drill-down list (Table/OutlineGroup). Selecting something shows a detail pane with the sizes, confidence, explanation, recommendation, command, and a "Reveal in Finder" button.
- **By folder:** the same treemap and list over the real folder layout, for anything the owner view doesn't explain.
- **History:** charts of growth over time per owner, and a per-scan diff.
- **Cleanup:** the selection, then the preview, then the run log (see below).
- **Scan coverage:** what was scanned, what couldn't be read (permissions, engine not running), and how long each part took.

The treemap is drawn with SwiftUI `Canvas` using a squarified layout. Flat collections like the Nix store are grouped by GC root or package name instead of hash-named folders.

## Cleanup (milestone 5)

1. **Select** items from any view. "Leave alone" items can't be selected. Review items each need their own tick.
2. **Preview.** This step is required and can't be skipped. It lists every action:
   - what gets removed (each image, path, generation or simulator, not just a total)
   - how (the exact tool command with its full arguments, or "Move to Trash")
   - the expected space freed and how confident that estimate is
   - the tier, plus warnings ("VM disk won't shrink until compacted", "needs admin: copy this command", "container engine must be running")
   - where the tool has a dry run (`brew cleanup -n`, `nix-store --gc --print-dead`), the preview is built from it. Otherwise the app lists the targets itself (for example the exact image IDs `docker image prune` would remove).
3. **Confirm.** One more prompt that shows the total and counts each type of action.
4. **Run.** Steps run one at a time with live output, can be cancelled between steps, and stop on the first failure.
5. **Verify.** The affected owners are measured again, and the app reports **predicted vs actually freed**.
6. **Log.** Every cleanup is saved with its preview, commands, output and result, so it can be reviewed later.

Safety rules: no `rm -rf` on user data, files only go to the Trash, commands run as fixed argument lists with no shell, never as root, and items are re-checked just before running (for example, is this image still unused?).

## History and insights

Every scan is saved to SQLite: volume stats, owner totals, and every item above a size threshold (default 100 MB), plus all items the tools reported. Scans run when the app launches or on demand in v1. Background scans come later.

Insights to try (keep the ones that prove useful):
- **What changed:** new, grown, shrunk and removed items since the last scan, last week, or any date you pick.
- **Growth rate per owner** ("untagged container images: +18 GB/week"), with recurring offenders pointed out.
- **Days until full** at the current growth rate.
- **Space that comes back:** items cleaned that grow back within days (rebuildable caches). Cleaning them gives only temporary relief, and the app says so.
- **Build-up patterns:** for example "12 new dated worktrees of one repo this month", or "test-image builds leave about N untagged images a day", which suggests a regular prune or a change to how builds are run.
- **Did cleanup help:** each cleanup's freed space against how fast it was used up again.

## Milestones

**M0: Check what's possible on a real Mac.** One throwaway app, `MacStorageProbe` (in `spikes/m0-probe/`), built, signed with the self-signed certificate (option A) and released by CI. It changes nothing on disk except a temporary test folder that it removes again. It checks:
- **Install and signing:** does the downloaded app open after removing the quarantine mark, what signature and designated requirement it carries, and whether the quarantine mark is present.
- **Full Disk Access:** can it be granted under MDM, and does it survive installing the next release (two releases, `probe-v0.1.0` and `probe-v0.1.1`, signed with the same certificate).
- **APFS sizes:** logical vs allocated vs private size for a normal file, a clone, a modified clone, a sparse file and a hard link.
- **Tools and PATH:** the PATH a GUI app gets vs the login shell's, and where each supported tool lives.
- **Discovery:** read-only commands and size measurements for every owner in the table above. Container engines that aren't running are left alone.
- **Report:** everything ends up in one report that is anonymized in the app (see "Keeping it anonymous"), shown for review, and saved only when asked. Reviewed reports become test fixtures.

Result: an updated plan with the paths, commands and distribution option confirmed.

**What M0 showed** (an unmanaged Mac on macOS 26, Apple Silicon):
- **Install:** the self-signed release opens normally when downloaded with `curl` (no quarantine mark). A browser download gets "Apple could not verify…", as expected. Full Disk Access can be granted. Still open: whether it survives an update, and everything on a managed Mac.
- **APFS:** `ATTR_CMNEXT_PRIVATESIZE` works. A fresh clone has private size 0 on both copies; after 2 MiB of one copy changes, both report 2 MiB private. The clone refcount and clone ID are also available. Allocated size (`st_blocks`, `totalFileAllocatedSize`) counts clones in full, so a folder of clones can be roughly twice its real cost (one worktree group: 6.4 GB allocated, 3.9 GB private). Sparse files report correctly (1 GiB logical, 1 MiB allocated).
- **Volumes:** "available for important use" is 0 on the `/nix` volume, so the app uses plain available capacity there. The VM, Preboot and Recovery volumes and the Nix volume show up in `diskutil apfs list` with their consumed sizes, which is enough to explain "System Data" at the top level.
- **Docker:** the `default` and `desktop-linux` contexts can be the same engine, so engines are de-duplicated by engine ID. The VM disk is 64 GB logical but 50 GB allocated, against about 36 GB of content inside, and `system df` already reports what's reclaimable per type (build cache was the largest).
- **Nix:** finding dead paths took about 5 s and sizing them about 6 s, quick enough to run on every scan (the sizes are NAR sizes, an estimate of the disk cost). `darwin-rebuild --list-generations` needs root, so generations are read from `/nix/var/nix/profiles/system-*-link` instead.
- **PATH:** started from Terminal with `open`, the app inherited the shell's PATH. Started from Finder or the Dock it won't, so locating tools explicitly stays necessary.
- **Big owners outside the developer stack:** Downloads, messaging-app data in `~/Library/Group Containers`, AI model folders, IDE caches in `~/Library/Caches` and `~/Library/Application Support`. Owners therefore include **apps**, identified by bundle ID and shown with the app's real name and icon, not just tools.
- **Speed:** a full discovery took about 6.5 minutes (home folders 3 minutes, git checkouts close to 2). The real app needs results that appear as they come in, parallel measurement, and caching between scans.
- **Anonymizing:** the first report exposed a scrubber bug (home paths weren't anonymized when the account's full name contained the username). It's fixed, with regression tests, before any report becomes a fixture.

**M1: UI/UX design.** An interactive HTML mockup of every main view, filled with real (anonymized) numbers from M0, iterated until the layout and wording are right. No Swift until it's agreed.

**M2: Scanner and folder view**
- Package skeleton, XcodeGen project, CI (Linux: `StorageCore` tests; macOS runner: build plus all tests), and a tag-triggered release job that signs (and, with option B, notarizes) the app, zips it and publishes it to GitHub Releases.
- An About window that shows the version and commit, so it's clear which build is installed.
- Volume overview, APFS-aware walk, folder treemap and list, scan coverage report.

**M3: Owners and recommendations**
- One provider per tool from the table, matching rules, tiers, detail pane with commands to copy. Fixture-based tests for every parser and rule.

**M4: History**
- SQLite store, diffs, growth charts, the insights above.

**M5: Cleanup**
- Selection, preview, confirm, run, verify and log, as described above, starting with the Safe tier and adding the others once that flow has proven itself.

**Before relying on it on a managed Mac:** repeat the M0 install and Full Disk Access checks there, then pick option A or B.

**Later**
- Background scans (login item or LaunchAgent), low-space notifications, menu-bar extra showing free space and the biggest recent growth.

## Development without a Mac at hand

- Most of the logic (parsers, rules, math, diffing, planning, anonymizing) is pure Swift, built and tested on Linux, using fixtures captured on a real Mac.
- macOS CI runners compile the full app and run all tests on every push.
- To try a change on a Mac: push a `v*` tag (or `probe-v*` in M0), wait for the release job, download the zip from GitHub Releases, move the app to `/Applications`, remove the quarantine mark (option A only), and open it. No Xcode needed on the Mac. Builds from any branch are also downloadable from the CI run's artifacts, signed the same way.
- Problems that only show up on a real Mac come back as an anonymized "Export diagnostics" report from the app, which becomes a new test fixture.

## Repository

- Public, so CI on macOS runners and CodeQL code scanning are free.
- A personal project, shared as is: issues, wiki, projects and discussions are turned off, and outside pull requests may never be looked at. CI on pull requests from first-time contributors needs approval, and signing secrets are never available to pull requests.

## Keeping it anonymous

Nothing in the repository, its CI logs or its releases should identify the person using it, their employer, their machine or their projects.

- Commits use the GitHub no-reply address of the repository owner, with UTC timestamps.
- The signing certificate has a generic name (`macstorage self-signed`).
- Reports from a real Mac are anonymized inside the app before they're shown or saved: home path and username, host and computer names, emails, URLs, IP addresses, UUIDs, volume names, git remotes, container image/container/volume names, and every folder name under the home folder that isn't a well-known tool or system name are replaced with stable placeholders such as `dir-12` or `image-3`. Shapes are kept (for example a dated suffix `dir-4-20261006`), so they're still useful as fixtures. Extra words (an employer's name, say) can be added to the redaction list, and the report is reviewed before it's saved.
- Raw, unscrubbed output never leaves the Mac and is never committed.

## Open questions

- License. None is set yet, which means "all rights reserved". MIT would let others reuse it freely.
