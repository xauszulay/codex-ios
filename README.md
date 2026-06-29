# Codex CLI for iOS (unofficial jailbreak port)

Unofficial iOS jailbreak port of **OpenAI Codex CLI** — the local coding
agent / Rust TUI — repackaged as a self-contained `.deb` for jailbroken iOS
(Dopamine / Procursus bootstrap, NewTerm 3, zsh).

> **Not an official OpenAI build.** Upstream Codex CLI is
> [github.com/openai/codex](https://github.com/openai/codex) (Apache-2.0).
> This repo only repackages a cross-compiled `aarch64-apple-ios` build of it
> for jailbroken iOS, adds a Settings.app pane, and wires up the install.
> Ported and maintained by **tg@xauszulay**.

After install, the `codex` command works in NewTerm with no extra config,
mirroring the Claude Code iOS package layout. A **Codex** pane in
Settings.app lets you tweak the model, sandbox, approvals and more, plus
action buttons (open config/logs, reset auth, run diagnostics) — no
`config.toml` editing required.

---

## Features

- `codex` command in NewTerm 3 / zsh — native Rust TUI, no Node needed for
  the engine.
- `codex-auth` helper for API key / ChatGPT login (uses the bundled Node).
- **Settings.app pane** (PreferenceLoader) with:
  - model picker (gpt-5-codex / gpt-5 / gpt-5-mini / gpt-4.1 / gpt-4.1-mini
    / o4-mini / o3)
  - sandbox mode (read-only / workspace-write / danger-full-access)
  - approval policy (untrusted / on-request / never)
  - toggles: web search, no-alt-screen, fast mode, memories
  - log level, API key
  - **action buttons**: Open Config Folder, Open Logs, Reset Authentication,
    Run Diagnostics, Respring
  - **links**: open.ai, upstream repo
- Self-contained install under `/var/jb/usr/local/lib/codex` — PATH-independent.
- ldid ad-hoc signing + entitlements (no-sandbox, allow-jit) so the TUI can
  spawn `git`/shell children.

---

## Repo layout

```
.
├── build-deb.sh              assemble the .deb on-device (or on a Mac)
├── .gitignore                ignores the big binaries + build junk
├── codex-ios/                the .deb package tree (dpkg-deb builds this)
│   ├── DEBIAN/               control, postinst, prerm, postrm
│   └── var/jb/…              install layout under the jailbreak root
│       ├── usr/local/bin/         codex, codex-auth wrappers
│       ├── usr/local/lib/codex/   native engine + bundled Node + shims
│       │   ├── codex-ios.MISSING  ← drop the built ~200 MB binary here
│       │   ├── node.MISSING       ← drop the bundled Node binary here
│       │   ├── entitlements.xml   ldid entitlements blob
│       │   ├── launcher.mjs       JS launcher fallback (debugging only)
│       │   ├── segmenter-shim.cjs Intl.Segmenter polyfill for Node
│       │   └── package.json
│       ├── usr/local/share/doc/codex/README.md  in-package docs
│       └── Library/
│           ├── PreferenceLoader/Preferences/   Settings pane entry + icons
│           ├── PreferenceBundles/CodexPrefs.bundle/  compiled pane (build it)
│           └── MobileSubstrate/Icons/          Sileo/Zebra package icon
└── prefs-bundle/             Theos project for the Settings.app pane
    ├── CodexPrefsController.m   PSListController + action buttons
    ├── Makefile                 Theos bundle.mk
    ├── Resources/CodexPrefs.plist  specifier list (rows the pane shows)
    └── control                  build-only Theos control file
```

> **Two binaries are NOT in git** (GitHub's 100 MB file cap, and they are
> artifacts, not source): the native `codex-ios` engine (~200 MB) and the
> bundled `node` (~70 MB). They ship as `*.MISSING` placeholder files with
> instructions. Drop them in before building the deb — see
> [Build the .deb](#build-the-deb) below.

---

## Requirements

On the iPhone (install target):

- Jailbroken iOS 16.x
- **Dopamine** jailbreak + **Procursus** bootstrap
- **PreferenceLoader** (the deb `Depends:` on it)
- NewTerm 3 (or any on-device terminal with zsh/sh)
- `dpkg-deb`, `ldid` (both ship with Procursus / Dopamine)

To build the native engine (one-time, on a Mac):

- macOS with Xcode 15+ and the iPhoneOS SDK
- Rust stable + the `aarch64-apple-ios` target
- `ldid` (`brew install ldid`)

To build the Settings pane (on a Mac, seconds):

- [Theos](https://theos.dev) installed (`THEOS` env var pointing at it)

---

## Quick start (on the phone, from a release)

If you grabbed a prebuilt `com.openai.codex-ios_*.deb` from Releases:

```sh
sudo dpkg -i com.openai.codex-ios_0.142.3_iphoneos-arm64.deb
# then respring if Settings.app doesn't show the Codex pane immediately
```

Then in NewTerm:

```sh
codex-auth   # set your API key (or ChatGPT login) — one time
codex        # launch the TUI
```

Open Settings.app → scroll to **Codex** to tweak model / sandbox / approvals
and use the action buttons.

---

## Build the .deb

The deb is assembled on-device (or on a Mac with `dpkg-deb`) from the
`codex-ios/` tree. Two binaries must be dropped in first.

### 1. Drop in the native engine

Place the built `aarch64-apple-ios` `codex` binary at
`codex-ios/var/jb/usr/local/lib/codex/codex-ios` (replacing the
`codex-ios.MISSING` placeholder). See
[Build the native engine](#build-the-native-engine-optional-mac) below, or
copy it from an existing install:

```sh
cp /var/jb/usr/local/lib/codex/codex-ios \
   codex-ios/var/jb/usr/local/lib/codex/codex-ios
chmod 0755 codex-ios/var/jb/usr/local/lib/codex/codex-ios
```

### 2. Drop in the bundled Node (for codex-auth)

Place an arm64-ios `node` binary at
`codex-ios/var/jb/usr/local/lib/codex/node` (replacing `node.MISSING`).
Easiest source is the Claude Code iOS bundle:

```sh
cp /var/jb/usr/local/lib/claude-code/node \
   codex-ios/var/jb/usr/local/lib/codex/node
chmod 0755 codex-ios/var/jb/usr/local/lib/codex/node
```

### 3. Build the Settings pane (Theos)

```sh
cd prefs-bundle
THEOS=/path/to/theos make clean package
# copy the built CodexPrefs.bundle contents into the deb tree:
cp -R .theos/obj/install/CodexPrefs.bundle/* \
   ../codex-ios/var/jb/Library/PreferenceBundles/CodexPrefs.bundle/
cd ..
```

If you skip this, run `./build-deb.sh --force` — the deb builds but the
Settings pane won't load.

### 4. Assemble the deb

```sh
./build-deb.sh
# → com.openai.codex-ios_0.142.3_iphoneos-arm64.deb
sudo dpkg -i com.openai.codex-ios_0.142.3_iphoneos-arm64.deb
```

`build-deb.sh` checks that the native engine and the prefs-bundle dylib are
present (use `--force` to bypass either check) and strips the `*.MISSING`
placeholders so they don't ship in the deb.

---

## Build the native engine (optional, Mac)

The iPhone has no Rust toolchain, so cross-compile on a Mac. This is the
slow part (~1–1.5 h for a release build). It only needs to be done once per
Codex version.

```sh
# Prereqs
xcode-select --install
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-apple-ios
brew install ldid

# Clone upstream at the version in DEBIAN/control
git clone https://github.com/openai/codex.git
cd codex/codex-rs
git checkout rust-v0.142.3

# Cross-compile
cargo build --release --target aarch64-apple-ios --bin codex

# Ad-hoc sign with the entitlements shipped in this repo
ldid -S<path-to-this-repo>/codex-ios/var/jb/usr/local/lib/codex/entitlements.xml \
  target/aarch64-apple-ios/release/codex

# Drop it into the deb tree
cp target/aarch64-apple-ios/release/codex \
   <path-to-this-repo>/codex-ios/var/jb/usr/local/lib/codex/codex-ios
```

A few upstream crates assume macOS and need iOS cfg gates (arboard/AppKit
clipboard, the `-ObjC` linker flag in `cli/build.rs`, etc.). The patches
that make it link are documented in the in-package README at
`codex-ios/var/jb/usr/local/share/doc/codex/README.md` (§2.2). Apply them
in the upstream checkout before `cargo build`.

> Why not just use the official darwin-arm64 binary? It links AppKit
> (absent on iOS) and is tagged `platform=1` (macOS), so dyld SIGKILLs it
> on iOS (exit 137). A native `aarch64-apple-ios` build is required.

---

## Install / verify / remove

```sh
# Install
sudo dpkg -i com.openai.codex-ios_0.142.3_iphoneos-arm64.deb

# Verify
which codex          # /var/jb/usr/local/bin/codex
codex --version      # 0.142.3 if the native binary is present
codex-auth           # one-time auth
codex                # launch the TUI

# Remove (keep ~/.codex config/auth)
sudo dpkg -r com.openai.codex-ios

# Purge (also wipe ~/.codex and the Settings prefs domain)
sudo dpkg --purge com.openai.codex-ios
```

---

## How the Settings pane works

The pane is a compiled PreferenceLoader bundle (`CodexPrefs.bundle`) whose
dylib (`CodexPrefsController`, a `PSListController` subclass) loads its row
specifiers from `CodexPrefs.plist` inside the bundle. Editable rows read/
write the `com.openai.codex-ios` cfprefsd domain; the `codex` wrapper reads
that same domain at launch, so changes take effect on the next `codex` run.

Action buttons are Objective-C methods on the controller (PSButtonCell
`action` selectors): they open folders via the Filza URL scheme, run shell
via `NSTask` (`/var/jb/bin/sh -c`), and post alerts. Source is in
`prefs-bundle/CodexPrefsController.m`.

The deb's `postinst` ad-hoc signs the dylib with `ldid` and sets
`root:wheel` ownership so Preferences.app loads it.

---

## Attribution & license

- **Upstream Codex CLI**: Copyright OpenAI, licensed Apache-2.0 —
  [github.com/openai/codex](https://github.com/openai/codex). This project
  is an unofficial repackaging and is not affiliated with or endorsed by
  OpenAI.
- **iOS port, packaging, and Settings pane**: tg@xauszulay.

No OpenAI source code is included in this repo — only packaging scripts,
the Settings pane source, and install metadata. The native engine and
bundled Node are built by you from upstream sources (or copied from an
existing install) and are intentionally gitignored.
