#!/var/jb/bin/sh
# build-deb.sh — assemble com.openai.codex-ios_*.deb on-device.
# Run from the directory that contains the `codex-ios/` package tree.
#
# The deb is assembled from a TEMPORARY COPY of the package tree so that the
# repo working tree is never mutated: the .MISSING placeholder files and the
# CodexPrefs.bundle/PLACEHOLDER file stay in the repo for git, while being
# stripped from the copy that goes into the deb.
set -eu

PKG_DIR="codex-ios"
VERSION="0.142.3"
OUT="com.openai.codex-ios_${VERSION}_iphoneos-arm64.deb"
BUNDLE_DIR="$PKG_DIR/var/jb/Library/PreferenceBundles/CodexPrefs.bundle"

# 1. Require the native engine to be present, unless --force is given.
#    The repo ships a codex-ios.MISSING placeholder (the real ~200 MB binary
#    is gitignored). Drop the built binary in as `codex-ios` before running.
if [ ! -x "$PKG_DIR/var/jb/usr/local/lib/codex/codex-ios" ]; then
    if [ "${1:-}" = "--force" ]; then
        echo "WARNING: native engine missing; building deb anyway (--force)."
    else
        echo "ERROR: $PKG_DIR/var/jb/usr/local/lib/codex/codex-ios is missing." >&2
        echo "       Build it on a Mac (see README §Build the native engine)," >&2
        echo "       or copy it from an existing install, and drop it in as" >&2
        echo "       codex-ios/var/jb/usr/local/lib/codex/codex-ios. Then re-run." >&2
        echo "       Or: $0 --force" >&2
        exit 1
    fi
fi

# 2. Require the bundled Node (for codex-auth). Fall back to the Claude bundle.
if [ ! -x "$PKG_DIR/var/jb/usr/local/lib/codex/node" ]; then
    if [ -x /var/jb/usr/local/lib/claude-code/node ]; then
        echo "Bundling Node from Claude Code install…"
        cp /var/jb/usr/local/lib/claude-code/node \
           "$PKG_DIR/var/jb/usr/local/lib/codex/node"
    else
        echo "WARNING: no bundled Node; codex-auth will not work." >&2
    fi
fi

# 2b. Require the compiled preference bundle (CodexPrefs.bundle). The dylib
#     must be built locally with Theos (see prefs-bundle/Makefile). It is a
#     single Objective-C file and builds in seconds, so no CI is provided.
#     A PLACEHOLDER file ships in the repo so the empty directory is tracked
#     by git.
if [ ! -f "$BUNDLE_DIR/CodexPrefs" ]; then
    if [ "${1:-}" = "--force" ]; then
        echo "WARNING: CodexPrefs.bundle dylib missing; Settings pane will not load (--force)."
    else
        echo "ERROR: $BUNDLE_DIR/CodexPrefs (the prefs bundle dylib) is missing." >&2
        echo "       Build it locally: cd prefs-bundle && THEOS=/path/to/theos make clean package" >&2
        echo "       then copy the built CodexPrefs.bundle contents into $BUNDLE_DIR/." >&2
        echo "       Then re-run. Or: $0 --force (Settings pane will be disabled)." >&2
        exit 1
    fi
fi

# 3. Make a temporary copy of the package tree. Everything below mutates the
#    COPY, not the repo, so placeholder files / build artifacts stay intact.
WORK="$(mktemp -d -t codex-deb.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "Copying package tree to $WORK …"
# cp -a preserves perms/ownership info; --reflink=auto avoids copying big
# binaries when the filesystem supports it (fast on APFS).
cp -a "$PKG_DIR" "$WORK/codex-ios"
PKG="$WORK/codex-ios"
BUNDLE="$PKG/var/jb/Library/PreferenceBundles/CodexPrefs.bundle"

# 4. Strip the repo-only placeholder files from the COPY so they do not ship
#    in the deb: the *.MISSING engine/node placeholders and the bundle
#    PLACEHOLDER file. The repo working tree is untouched.
rm -f "$PKG"/var/jb/usr/local/lib/codex/*.MISSING 2>/dev/null || true
rm -f "$BUNDLE/PLACEHOLDER" 2>/dev/null || true

# 5. Permissions on the COPY.
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"
chmod 0755 "$PKG/var/jb/usr/local/bin/codex" \
           "$PKG/var/jb/usr/local/bin/codex-auth"
[ -x "$PKG/var/jb/usr/local/lib/codex/codex-ios" ] && \
    chmod 0755 "$PKG/var/jb/usr/local/lib/codex/codex-ios"
[ -x "$PKG/var/jb/usr/local/lib/codex/node" ] && \
    chmod 0755 "$PKG/var/jb/usr/local/lib/codex/node"
chmod 0644 "$PKG/var/jb/usr/local/lib/codex/segmenter-shim.cjs" \
           "$PKG/var/jb/usr/local/lib/codex/launcher.mjs" \
           "$PKG/var/jb/usr/local/lib/codex/entitlements.xml" \
           "$PKG/DEBIAN/control"
# PreferenceLoader pane (entry plist + icons) ships as 0644; postinst re-owns
# them to root:wheel to match the other tweaks in that directory.
chmod 0644 "$PKG/var/jb/Library/PreferenceLoader/Preferences/CodexIOS.plist" \
           "$PKG/var/jb/Library/PreferenceLoader/Preferences/codex.png" \
           "$PKG/var/jb/Library/PreferenceLoader/Preferences/codex@2x.png" \
           "$PKG/var/jb/Library/PreferenceLoader/Preferences/codex@3x.png" 2>/dev/null || true
# Sileo/Zebra package icon (local fallback for the Icon: URL in control).
chmod 0644 "$PKG/var/jb/Library/MobileSubstrate/Icons/codex-sileo.png" 2>/dev/null || true

# Compiled preference bundle (CodexPrefs.bundle). The dylib is 0755; the
# plist resources are 0644. postinst re-owns everything to root:wheel and
# ad-hoc signs the dylib with ldid.
if [ -d "$BUNDLE" ]; then
    chmod 0755 "$BUNDLE"
    [ -f "$BUNDLE/CodexPrefs" ] && chmod 0755 "$BUNDLE/CodexPrefs"
    [ -f "$BUNDLE/CodexPrefs.plist" ] && chmod 0644 "$BUNDLE/CodexPrefs.plist"
    [ -f "$BUNDLE/Info.plist" ] && chmod 0644 "$BUNDLE/Info.plist"
    # Pane icon and its @2x/@3x siblings. PreferenceLoader resolves the entry
    # plist's `icon` key against the detail bundle, so the PNGs must ship
    # inside CodexPrefs.bundle (not only in PreferenceLoader/Preferences/).
    chmod 0644 "$BUNDLE"/codex.png "$BUNDLE"/codex@2x.png "$BUNDLE"/codex@3x.png 2>/dev/null || true
fi

# 6. Build.
echo "Building $OUT …"
dpkg-deb --root-owner-group -Zgzip -b "$PKG" "$OUT"

echo "Done: $OUT"
ls -la "$OUT"
echo ""
echo "Install with: sudo dpkg -i $OUT"
