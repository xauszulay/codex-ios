# Codex CLI for iOS (Dopamine / Procursus)

OpenAI Codex CLI repackaged as a self-contained `.deb` for jailbroken iOS
(iPhone 14 Pro Max, iOS 16.1, Dopamine, Procursus bootstrap, NewTerm 3, zsh).

After install, the `codex` command is available in NewTerm with no extra
configuration, mirroring the existing Claude Code iOS package layout.

## 1. Architecture summary

Codex CLI is **not** a Node program. As of v0.142.3 the upstream repo
(`github.com/openai/codex`) is a **Rust workspace** under `codex-rs/`.
The `@openai/codex` npm package is only a thin ESM launcher
(`bin/codex.js`) that maps `(platform, arch)` to a platform-specific npm
package (`@openai/codex-darwin-arm64`, etc.) which vendors a prebuilt
**native Rust binary** under `vendor/<triple>/bin/codex`. Node ≥22 is
required only by that launcher; the engine itself is pure native.

Upstream CI builds exactly four targets:

- `aarch64-apple-darwin`   (macOS Apple Silicon)
- `x86_64-apple-darwin`    (macOS Intel)
- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`

There is **no `aarch64-apple-ios` target** and no iOS CI job.

### Why the official darwin-arm64 binary does NOT run on iOS

The `codex-aarch64-apple-darwin` release is a 249 MB Mach-O arm64
executable linked against macOS frameworks:

- `/System/Library/Frameworks/AppKit.framework`        ← **absent on iOS**
- `CoreGraphics`, `CoreServices`, `SystemConfiguration`
- `CoreFoundation`, `Foundation`, `Security`, `CFNetwork`, `IOKit`
- `/usr/lib/libSystem.B.dylib`, `libobjc.A.dylib`, `liblzma.5`, `libbz2.1.0`

`LC_BUILD_VERSION` says `platform 1` (macOS), `minos 11.0`, `sdk 15.5`.

On the iPhone, `AppKit.framework` does not exist (iOS uses `UIKit`).
Running the binary dies immediately with SIGKILL (exit 137). The AppKit
references are minimal — only `NSPasteboardTypeTIFF` and
`NSPasteboardURLReadingFileURLsOnlyKey`, pulled in transitively by the
`arboard` clipboard crate (→ `objc2-app-kit`). But the binary is still
hard-linked against AppKit, so dyld refuses it on iOS regardless.

Conclusion: **the official binary cannot be used directly.** A native
`aarch64-apple-ios` build is required.

### What this package ships

```
/var/jb/usr/local/bin/codex                 zsh wrapper (primary entry point)
/var/jb/usr/local/bin/codex-auth            auth helper (API key / ChatGPT)
/var/jb/usr/local/lib/codex/codex-ios       native aarch64-apple-ios Rust engine  ← YOU MUST BUILD THIS
/var/jb/usr/local/lib/codex/node            bundled Node 22 arm64-ios (auth helper only)
/var/jb/usr/local/lib/codex/launcher.mjs    JS launcher fallback (debugging only)
/var/jb/usr/local/lib/codex/segmenter-shim.cjs  Intl.Segmenter polyfill for Node
/var/jb/usr/local/lib/codex/entitlements.xml    ldid entitlements blob
```

The wrapper launches the native engine directly. Node is used **only** by
`codex-auth` and the optional launcher fallback, exactly like Claude Code
iOS uses its bundled Node for `claude-auth` and the JS CLI.

## 2. Building the native iOS engine (on a macOS host)

The iPhone itself has no Rust toolchain, so cross-compile on a Mac.

### 2.1 Prerequisites (macOS host)

```sh
# Xcode + iOS SDK (Xcode 15+ recommended)
xcode-select --install

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# iOS target + linker
rustup target add aarch64-apple-ios
# ldid for ad-hoc signing with entitlements (optional but recommended)
brew install ldid
```

### 2.2 Clone and patch

```sh
git clone https://github.com/openai/codex.git
cd codex/codex-rs
git checkout rust-v0.142.3   # match the version in DEBIAN/control
```

Two crate features assume macOS and pull AppKit/Security. On iOS they
must be redirected:

- `codex-keyring-store` uses `keyring` with feature `apple-native`
  (Security framework keychain). On iOS the Security framework exists,
  but the `apple-native` keyring backend is gated to `target_os = "macos"`
  upstream. For iOS, either disable keyring (auth via API key / file) or
  switch to the `crypto-rust` + file store. Simplest: build without the
  keyring apple-native path by editing
  `codex-rs/keyring-store/Cargo.toml`:
  ```toml
  [target.'cfg(target_os = "ios")'.dependencies]
  keyring = { workspace = true, features = ["crypto-rust"] }
  ```
  and add an `ios` arm to the existing `cfg(target_os = "macos")` block.

- `system-configuration` crate (SystemConfiguration.framework) is used
  for proxy detection. iOS has `SystemConfiguration.framework`, but the
  crate may not compile for `target_os = "ios"`. If it fails, stub it:
  in the workspace `Cargo.toml`, gate `system-configuration` behind
  `cfg(not(target_os = "ios"))` and provide a no-op proxy config on iOS.

- `arboard` (clipboard) already supports iOS via `objc2-ui-kit`; on
  `target_os = "ios"` it will not pull `objc2-app-kit`. Confirm by
  checking `arboard` 3.6.1's `Cargo.toml` `target.'cfg(target_os = "ios")'`
  section.

### 2.3 Cross-compile

```sh
# From codex-rs/
cargo build --release \
  --target aarch64-apple-ios \
  --bin codex
```

The resulting binary:
`target/aarch64-apple-ios/release/codex`

If the build pulls in a crate that has no iOS support (e.g.
`linux-sandbox`, `windows-sandbox`), it is already `cfg`-gated and will
be skipped. If a macOS-only crate is reached, add an `ios` cfg gate as
in §2.2.

### 2.4 Sign with entitlements (ad-hoc)

```sh
ldid -S<path-to-this-package>/var/jb/usr/local/lib/codex/entitlements.xml \
  target/aarch64-apple-ios/release/codex
```

`com.apple.private.security.no-sandbox` + the `cs.allow-jit` /
`disable-library-validation` keys let the TUI spawn child processes
(git, shell commands) and use the iOS JIT path if needed. On Dopamine,
`TweakInject`/`ellekit` and `ldid` are already present; on the host use
the `brew install ldid` copy.

## 3. Assembling the .deb on the device (or host)

The package tree is already laid out in this directory. Drop the built
binary into place, then build:

```sh
# 1. Copy the built native engine in (done on the Mac, then transfer, or
#    build directly on-device if you transferred the toolchain):
cp target/aarch64-apple-ios/release/codex \
   codex-ios/var/jb/usr/local/lib/codex/codex-ios
chmod 0755 codex-ios/var/jb/usr/local/lib/codex/codex-ios

# 2. Bundle a Node 22 arm64-ios runtime next to it (for codex-auth).
#    The simplest source is the existing Claude Code bundle, which is
#    already a working iOS arm64 Node 18. Codex's launcher wants >=16,
#    so that binary works. For a true Node 22, build from
#    github.com/nicklama/node-ios or use the Procursus node package.
cp /var/jb/usr/local/lib/claude-code/node \
   codex-ios/var/jb/usr/local/lib/codex/node
chmod 0755 codex-ios/var/jb/usr/local/lib/codex/node

# 3. Make scripts executable.
chmod 0755 codex-ios/DEBIAN/postinst codex-ios/DEBIAN/prerm codex-ios/DEBIAN/postrm
chmod 0755 codex-ios/var/jb/usr/local/bin/codex codex-ios/var/jb/usr/local/bin/codex-auth

# 4. Build the deb (dpkg-deb is present in Procursus).
dpkg-deb --root-owner-group --Zgzip -b codex-ios com.openai.codex-ios_0.142.3_iphoneos-arm.deb
```

## 4. Install / verify / remove (on the iPhone)

```sh
# Install
sudo dpkg -i com.openai.codex-ios_0.142.3_iphoneos-arm.deb
# or via Sileo: drop the .deb into /var/jb/var/mobile/ and tap it.

# Verify
which codex                       # /var/jb/usr/local/bin/codex
codex --version                   # prints 0.142.3 if the native binary is present
codex-auth                        # set API key (option 1) or use ChatGPT (option 2)
codex                             # launch the TUI

# Remove (keep config)
sudo dpkg -r com.openai.codex-ios
# Purge (also drop ~/.codex)
sudo dpkg --purge com.openai.codex-ios
```

## 4b. Settings.app pane (PreferenceLoader)

After install, a **Codex** entry appears in Settings.app (requires
PreferenceLoader, listed in `Depends`). The pane is a compiled
PreferenceLoader bundle (`CodexPrefs.bundle`) hosting a
`CodexPrefsController` that reads/writes the `com.openai.codex-ios`
cfprefsd domain — the same domain the `codex` wrapper reads at launch.

Editable options:

- **Model** — gpt-5-codex / gpt-5 / gpt-5-mini / gpt-4.1 / gpt-4.1-mini /
  o4-mini / o3
- **Sandbox** — read-only / workspace-write / danger-full-access
- **Approval** — untrusted / on-request / never
- **Toggles** — web search, no-alt-screen, fast mode, memories
- **Log level** — info / debug / warning / error
- **API key** — stored in the `com.openai.codex-ios` prefs domain

Action buttons (Maintenance group):

- **Open Config Folder** — opens `~/.codex` via the Filza URL scheme
  (`filza://<path>`); falls back to an inline directory listing alert if
  Filza is not installed.
- **Open Logs** — opens `~/.codex/log` (or `~/.codex` if absent).
- **Reset Authentication** — confirms, then removes `~/.codex/auth.json` /
  `auth.toml` / `credentials` and clears the API key from the prefs domain.
- **Run Diagnostics** — prints version, native-binary presence, config dir
  listing, auth status and current settings to an alert.

Links group:

- **Open open.ai** — opens https://open.ai in the browser.
- **Open upstream repo** — opens https://github.com/openai/codex.

About group shows the version and the porter. A **Respring** button is
provided for reloading the pane after changes.

The bundle source lives in `prefs-bundle/` in the source repo; the deb's
`postinst` ad-hoc signs the dylib with `ldid` and sets `root:wheel` ownership
so Preferences.app loads it.

## 5. Known iOS-specific issues and fixes

| Issue | Cause | Fix |
|---|---|---|
| `exit 137` (SIGKILL) on launch | official darwin binary, missing AppKit | build `aarch64-apple-ios` (§2) |
| dyld: missing framework on launch | binary signed for macOS platform=1 | rebuild for iOS, re-sign with `ldid -S` |
| Sandbox denies spawn of `git`/shell | iOS sandbox on unsigned binaries | entitlements `no-sandbox` + `ldid -S` |
| `Intl.Segmenter` crash (Node helper) | V8 ICU data incomplete on iOS arm64 Node | `-r segmenter-shim.cjs` (already in wrapper) |
| TUI renders garbage / no color | wrong `$TERM` | wrapper sets `TERM=xterm-256color` |
| `TMPDIR` unset / unwritable | root ssh shell has no TMPDIR | wrapper sets `TMPDIR=$HOME/.codex/tmp` |
| Locale warnings | `en_US.UTF-8` not generated | wrapper falls back to `LANG=C` |
| Clipboard paste fails | AppKit path gone on iOS | `arboard` iOS backend (UIKit) — handled at build time |
| Keychain auth fails | `apple-native` keyring is macOS-only | switch to `crypto-rust` file store (§2.2) |
| `fork`/`posix_spawn` EPERM | sandbox | `no-sandbox` entitlement + Dopamine root |
| `fs.watch` / inotify | iOS has no inotify; FSEvents limited | Codex uses its own `file-watcher` crate; if it fails, run `codex exec` non-interactively |
| Large binary (249 MB) | debug info + many crates | `strip` the release binary; build with `--profile release` + `lto = "fat"` + `codegen-units = 1` in `Cargo.toml` to shrink |

## 6. Layout parity with Claude Code iOS

| Claude Code | Codex CLI |
|---|---|
| `/var/jb/usr/local/bin/claude` | `/var/jb/usr/local/bin/codex` |
| `/var/jb/usr/local/bin/claude-auth` | `/var/jb/usr/local/bin/codex-auth` |
| `/var/jb/usr/local/lib/claude-code/node` | `/var/jb/usr/local/lib/codex/node` |
| `/var/jb/usr/local/lib/claude-code/node_modules/@anthropic-ai/claude-code/cli.js` | `/var/jb/usr/local/lib/codex/codex-ios` (native) |
| `/var/jb/usr/local/lib/claude-code/segmenter-shim.js` | `/var/jb/usr/local/lib/codex/segmenter-shim.cjs` |
| `/var/jb/usr/local/lib/claude-code/entitlements.xml` | `/var/jb/usr/local/lib/codex/entitlements.xml` |

The key difference: Claude's engine is a Node JS file (`cli.js`) launched
by the bundled Node with V8 hardening flags. Codex's engine is a **native
Rust binary** launched directly — no V8 flags apply to it. The V8 flags
in the wrapper are only used by the Node fallback path.
