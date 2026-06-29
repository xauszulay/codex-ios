#!/usr/bin/env node
// Codex CLI JS launcher for iOS.
//
// This is a thin re-implementation of the upstream @openai/codex
// bin/codex.js entry point. Upstream maps (platform,arch) -> a platform
// npm package that vendors a prebuilt native binary. On iOS there is no
// such package, so this launcher is only useful when a working native
// binary has been placed under vendor/<triple>/bin/codex.
//
// In the normal iOS package flow the native binary at
// /var/jb/usr/local/lib/codex/codex-ios is launched directly by the
// zsh wrapper, and this file exists only as a debugging fallback.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const require = createRequire(import.meta.url);

// iOS reports process.platform === "darwin" && arch === "arm64". Upstream
// would pick the macOS aarch64-apple-darwin binary, which does NOT run on
// iOS (missing AppKit). Override to the iOS triple when we detect we are
// actually on iOS.
function detectTarget() {
  if (process.platform === "darwin" && process.arch === "arm64") {
    // Heuristic: iOS has /System/Library/Frameworks/UIKit.framework and
    // does NOT have AppKit.framework.
    const hasUIKit = existsSync("/System/Library/Frameworks/UIKit.framework");
    const hasAppKit = existsSync("/System/Library/Frameworks/AppKit.framework");
    if (hasUIKit && !hasAppKit) {
      return "aarch64-apple-ios";
    }
    return "aarch64-apple-darwin";
  }
  // Fall back to upstream mapping for other platforms.
  const map = {
    "linux-x64": "x86_64-unknown-linux-musl",
    "linux-arm64": "aarch64-unknown-linux-musl",
    "darwin-x64": "x86_64-apple-darwin",
    "win32-x64": "x86_64-pc-windows-msvc",
    "win32-arm64": "aarch64-pc-windows-msvc",
  };
  return map[`${process.platform}-${process.arch}`] || null;
}

const target = detectTarget();
if (!target) {
  throw new Error(`Unsupported platform: ${process.platform} (${process.arch})`);
}

// Look for the native binary in a few candidate locations.
function findBinary() {
  const candidates = [
    path.join(__dirname, "codex-ios"),            // iOS package layout (primary)
    path.join(__dirname, "vendor", target, "bin", "codex"),
    path.join(__dirname, "..", "vendor", target, "bin", "codex"),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  // Upstream platform package, if installed.
  try {
    const pkgByTarget = {
      "x86_64-unknown-linux-musl": "@openai/codex-linux-x64",
      "aarch64-unknown-linux-musl": "@openai/codex-linux-arm64",
      "x86_64-apple-darwin": "@openai/codex-darwin-x64",
      "aarch64-apple-darwin": "@openai/codex-darwin-arm64",
      "x86_64-pc-windows-msvc": "@openai/codex-win32-x64",
      "aarch64-pc-windows-msvc": "@openai/codex-win32-arm64",
    };
    const pkg = pkgByTarget[target];
    if (pkg) {
      const pkgJson = require.resolve(`${pkg}/package.json`);
      const p = path.join(path.dirname(pkgJson), "vendor", target, "bin", "codex");
      if (existsSync(p)) return p;
    }
  } catch {}
  return null;
}

const binary = findBinary();
if (!binary) {
  console.error(`Codex CLI for iOS: no native binary found for target ${target}.`);
  console.error(`  Place a build at: ${path.join(__dirname, "codex-ios")}`);
  process.exit(127);
}

// Async spawn so Node can forward signals (Ctrl-C) to the child.
const child = spawn(binary, process.argv.slice(2), {
  stdio: "inherit",
  env: process.env,
});

child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => child.kill(sig));
}
