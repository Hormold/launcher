# Launcher — context for Claude

A minimal, fast macOS app launcher. Dock icon → click → type → Enter. That's the entire UX.

## Goals (in priority order)

1. **Speed.** Cold start < 30 ms, search < 1 ms. Faster than Spotlight, faster than Raycast.
2. **Zero friction.** Single search input, no settings, no chrome. Open immediately on dock click, focused, ready.
3. **Reliability.** Auto-reindex on app install/uninstall (FSEvents). Stale entries self-heal. Corrupt cache recovers.
4. **Small.** Pure Swift + SwiftUI + AppKit. No third-party deps. No plugins.

## Non-goals (don't add)

- Global hotkey (dock click is the trigger — one mental model).
- Web search, calculator, clipboard history, snippets.
- Plugin system.
- Window management.
- Phonetic alias dictionaries (`ноушен` → Notion). Layout swap covers the realistic case; phonetic matching needs a pronunciation dict — out of scope.

If user wants any of these → they should use Raycast.

## Architecture

```
Sources/Launcher/
├── main.swift          # entry + CLI flags (--probe, --self-test, --bench, --integrity)
├── LauncherApp.swift   # @main, NSApp delegate, dock-reopen, multi-screen centering
├── ContentView.swift   # SwiftUI: search bar, results list, empty state
├── AppIndex.swift      # scan, cache, FSEvents, IndexedApp pre-computation
├── AgentLauncher.swift # project discovery and coding-agent terminal sessions
├── FSWatcher.swift     # FSEventStream wrapper (auto-reindex)
├── SearchEngine.swift  # byte-level fuzzy scorer
├── KeyboardLayout.swift # QWERTY ↔ ЙЦУКЕН swap
└── Recents.swift       # UserDefaults MRU + auto-prune missing paths
```

### Data flow

1. Launch → `AppIndex.loadCachedThenRefresh()` reads and validates the cache off the main thread, then rescans asynchronously.
2. Scan walks `/Applications`, `~/Applications`, `/System/Applications`, Utilities, Setapp, CoreServices/Applications + explicit `Finder.app`. Filters background services; user-installed menubar apps with icons remain searchable.
3. Each `AppEntry` gets wrapped in `IndexedApp` with **pre-computed UTF-8 byte arrays** for each alias and pre-split words. This is what powers the fast scorer.
4. `SearchIndex` precomputes alphabetical tie ranks and path offsets. Search ranks by tier: exact (1000) > prefix (500) > word-prefix (300) > substring (200) > subsequence (50+contiguity_bonus). Byte masks reject impossible matches. Recents add a small boost using integer offsets. The UI caches results until search inputs change.
5. Open → `AppIndex.open()` verifies path still exists; if not, removes from index and recents.

### Why byte-level, not String?

Swift `String` is grapheme-aware (`hasPrefix`, `contains` walk Unicode clusters). For app names that's overkill. UTF-8 byte sequences in distinct scripts (Latin / Cyrillic) never collide because of how UTF-8 encodes multi-byte chars. So `[UInt8]` byte loops via `memcmp` are correct AND ~2.5x faster.

### Why no global hotkey?

Dock click activates the app → `applicationShouldHandleReopen` / `applicationDidBecomeActive` fire → `showAndFocus()` re-centers, brings to front, posts `launcherShouldFocus`. Esc → `NSApp.hide(nil)` → app stays alive in dock for instant next click. This is the canonical macOS pattern.

## Build / test commands

```bash
bash build.sh                 # build .app
bash build.sh --run           # build + launch
bash build.sh --install       # build + replace in /Applications + refresh Dock
bash build.sh --sign          # build + code-sign with first keychain identity
bash build.sh --install --run # full dev loop
swift test -c release         # deterministic search regressions

# Diagnostics (run binary directly, exit before SwiftUI starts)
.build/release/Launcher --probe "notion"   # show variants and top 10
.build/release/Launcher --self-test        # 13 scenario tests
.build/release/Launcher --bench            # scan + search timing
.build/release/Launcher --integrity        # verify indexed paths still exist
```

## Performance budget

If any of these regress, treat it as a bug:

| metric | budget | historical reference |
|---|---|---|
| scan time | < 100 ms | ~50 ms (180 apps) |
| search avg | < 0.3 ms | 0.18 ms |
| RSS (GUI) | < 200 MB | ~115 MB |
| heap | < 30 MB | 13 MB |
| leaks | 0 | 0 |
| self-test | 13/13 | 13/13 |

Re-bench before merging perf-touching changes.
The October 13, 2026 comparison measured prepared search at 0.145 ms before and
0.033 ms after, across 184 apps with 20 recents. `--bench` reports index preparation
separately; GUI memory and end-to-end startup need their own measurements.

## Conventions

- macOS 14+ (uses `.onKeyPress`).
- Universal binary (arm64 + x86_64).
- macOS HIG icon: squircle fills ~80-100% of 1024×1024 canvas.
- Bundle id: `com.github.hormold.launcher`.
- Cache: `~/Library/Caches/Launcher/index.json`. Recents: `UserDefaults` key `launcher.recents`.
- Window: hidden title bar, full-size content view, `.normal` level (not `.floating` — playing nice with other apps).
- Colors: only `accentColor`, `secondary`, `tertiary` system tokens. No hardcoded hexes.
- Icon assets: `Resources/AppIcon.icns` is gitignored; rebuilt from `icon.png` by `build.sh`.

## Known trade-offs (decided, do not flip)

- **Background services hidden.** Pure background apps are skipped. User-installed menubar apps with icons and the explicit Finder entry remain indexed.
- **Layout swap, not phonetic.** "Notion typed on RU layout = `тщешщт`" → swap recovers. "ноушен" (phonetic) does NOT find Notion — out of scope.
- **No window animation tuning.** Use `NSApp.hide` (canonical) instead of fighting `orderOut` animation glitches.
- **No `@main` on `App` struct.** `main.swift` dispatches to CLI modes before `LauncherApp.main()`.

## Past traps to remember

- `NSViewRepresentable` for `NSTextField` + `@FocusState` is fragile. Caused query binding to silently break — typing chars without updating SwiftUI state, results showing alphabetic-first apps. **Stick with native SwiftUI `TextField` + `.onKeyPress`.** Don't rebuild custom text field unless absolutely needed.
- `didBecomeKeyNotification` observer must be **scoped to mainWindow** — otherwise random system panels becoming key trigger spurious focus events causing Esc-stuck-with-opacity bugs.
- Cache path is checked before publishing on launch — apps deleted between sessions don't ghost in the index.
- Don't include scanning under `/System/Library/CoreServices` directly — too much junk. Use `/System/Library/CoreServices/Applications` (curated subdir) + explicit Finder.
- Lazy result rows must use each result's identity. Index-based child IDs can leave the previous app's row visible after a query change.

## Release process

End-to-end shipping flow — bug-fix bumps patch (`v0.1.1` → `v0.1.2`), feature bumps minor.

```bash
# 1. commit fix(es) — single commit per release if possible, conventional message
git add <files>
git commit -m "..."

# 2. validate before tagging
.build/release/Launcher --self-test    # must be N/N
.build/release/Launcher --bench        # scan + search within budget (CLAUDE.md table)

# 3. push main, tag, push tag
git push origin main
git tag vX.Y.Z
git push origin vX.Y.Z

# 4. build .app from clean tree, zip artifact
bash build.sh
ditto -c -k --sequesterRsrc --keepParent Launcher.app Launcher-vX.Y.Z.zip

# 5. create GH release with inline notes via HEREDOC (no separate notes file)
gh release create vX.Y.Z \
  --title "vX.Y.Z — <short summary>" \
  --notes "$(cat <<'EOF'
### Fixes
- ...

### Numbers
- Index, scan, search, self-test counts (only if perf-relevant)

### Install
Unzip and drop \`Launcher.app\` into \`/Applications\`.
EOF
)" \
  Launcher-vX.Y.Z.zip
```

Notes: keep release notes terse and user-facing — what changed + why it matters, not commit history. Include perf numbers only when fix touches scan/search. Don't push tag before commit lands on main (release will point at wrong sha).

For Mac App Store / wider distribution: needs Developer ID Application cert + notarization. Not set up yet — `bash build.sh --sign` uses Apple Development cert (works only on dev machine).
