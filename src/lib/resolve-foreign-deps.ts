#!/usr/bin/env bun
// Resolve foreign (non-Nix) ELF binary dependencies via nix-locate.
//
// Usage as CLI (for testing):
//   resolve-foreign-deps.ts <binary>
// Prints scan results, resolved attrs, and interpreter info.

import { existsSync, readdirSync } from "node:fs";
import { basename } from "node:path";
import { nixBuild, nixLocate, nixStoreReferences } from "./nix.ts";
import { printNeeded } from "./patchelf.ts";
import type { BuildResult, InterpreterInfo, ResolveResult, ScanResult } from "./types.ts";

function log(msg: string): void {
  console.error(msg);
}

function regexEscape(s: string): string {
  return s.replace(/[.+*?^${}()|\\]/g, "\\$&");
}

// Preferred package prefixes — when multiple packages provide the same library,
// prefer these well-known system packages.
const PREFERRED_ATTR_RE =
  /^(glibc|libgcc|gcc|zlib|openssl[_0-9]*|curl|xorg\.|libGL|libglvnd|glib|gtk[34]|cairo|pango|gdk-pixbuf|dbus|fontconfig|freetype|expat|libffi|sqlite|ncurses|readline|xz|zstd|bzip2|pcre2)\./;

/** Find the nixpkgs attribute that provides a given library. */
function findLibAttr(libname: string, extraPreferred?: RegExp): string | null {
  const escaped = regexEscape(libname);
  const results = nixLocate(`/lib/${escaped}$`);
  if (results.length === 0) return null;
  if (extraPreferred) {
    const extra = results.find((r) => extraPreferred.test(r));
    if (extra) return extra;
  }
  const preferred = results.find((r) => PREFERRED_ATTR_RE.test(r));
  return preferred ?? results[0];
}

/** Scan a binary's dynamic dependencies. */
export function scanNeeded(target: string): ScanResult {
  const needed = printNeeded(target);
  const result: ScanResult = { needed: [], interpNeeded: null };

  for (const lib of needed) {
    if (/^ld-linux/.test(lib)) {
      result.interpNeeded = lib;
    } else {
      result.needed.push(lib);
    }
  }

  return result;
}

/** Resolve needed libraries to nixpkgs attributes via nix-locate. */
export function resolveLibs(scan: ScanResult, preferPkgs?: string[]): ResolveResult {
  const extraPreferred =
    preferPkgs && preferPkgs.length > 0
      ? new RegExp(`^(${preferPkgs.map(regexEscape).join("|")})\\.`)
      : undefined;

  const result: ResolveResult = {
    libToAttr: new Map(),
    interpAttr: null,
    notFound: [],
  };

  for (const lib of scan.needed) {
    const attr = findLibAttr(lib, extraPreferred);
    if (attr === null) {
      result.notFound.push(lib);
      log(`  ${lib} -> NOT FOUND`);
    } else {
      log(`  ${lib} -> ${attr}`);
      result.libToAttr.set(lib, attr);
    }
  }

  if (scan.interpNeeded) {
    const attr = findLibAttr(scan.interpNeeded, extraPreferred);
    if (attr) {
      log(`  ${scan.interpNeeded} -> ${attr} (interpreter)`);
      result.interpAttr = attr;
    } else {
      log(`  ${scan.interpNeeded} -> NOT FOUND (interpreter)`);
      result.notFound.push(scan.interpNeeded);
    }
  }

  if (result.notFound.length > 0) {
    log("");
    log(`Warning: could not find packages for: ${result.notFound.join(" ")}`);
  }

  return result;
}

/** Build resolved nixpkgs attributes and record store paths. */
export function buildPackages(resolved: ResolveResult, nixpkgsRev?: string): BuildResult {
  const attrToStorePath = new Map<string, string>();

  // Collect all unique attrs
  const attrs = new Set(resolved.libToAttr.values());
  if (resolved.interpAttr) attrs.add(resolved.interpAttr);

  const flakePrefix = nixpkgsRev ? `github:NixOS/nixpkgs/${nixpkgsRev}` : "nixpkgs";
  for (const attr of attrs) {
    log(`  nix build ${flakePrefix}#${attr}`);
    const storePath = nixBuild(attr, nixpkgsRev);
    attrToStorePath.set(attr, storePath);
  }

  return { attrToStorePath };
}

/** Find ld-linux-*.so.* files in a directory. */
function findLdLinux(libDir: string): string | null {
  if (!existsSync(libDir)) return null;
  try {
    const entries = readdirSync(libDir);
    const ldLinux = entries.find((e) => /^ld-linux-.*\.so\./.test(e));
    return ldLinux ? `${libDir}/${ldLinux}` : null;
  } catch {
    return null;
  }
}

/** Find the dynamic linker from resolved packages. */
export function findInterpreter(
  resolved: ResolveResult,
  build: BuildResult,
): InterpreterInfo | null {
  // Strategy 1: ld-linux was explicitly in NEEDED
  if (resolved.interpAttr) {
    const sp = build.attrToStorePath.get(resolved.interpAttr);
    if (sp) {
      const interp = findLdLinux(`${sp}/lib`);
      if (interp) {
        return { path: interp, basename: basename(interp), extraStorePath: null };
      }
    }
  }

  // Strategy 2: libc.so resolved to glibc — ld-linux should be in the same package
  for (const [lib, attr] of resolved.libToAttr) {
    if (/^libc\.so\./.test(lib)) {
      const sp = build.attrToStorePath.get(attr);
      if (sp) {
        const interp = findLdLinux(`${sp}/lib`);
        if (interp) {
          return { path: interp, basename: basename(interp), extraStorePath: null };
        }
      }
      break;
    }
  }

  // Strategy 3: search dependencies of resolved packages
  log("Warning: could not find interpreter directly; searching package dependencies...");
  for (const sp of build.attrToStorePath.values()) {
    const refs = nixStoreReferences(sp);
    for (const dep of refs) {
      const interp = findLdLinux(`${dep}/lib`);
      if (interp) {
        return { path: interp, basename: basename(interp), extraStorePath: dep };
      }
    }
  }

  return null;
}

// CLI mode
if (import.meta.main) {
  const target = process.argv[2];
  if (!target) {
    console.error("Usage: resolve-foreign-deps.ts <binary>");
    process.exit(1);
  }

  log("==> Scanning dependencies");
  const scan = scanNeeded(target);
  console.log(`needed: ${scan.needed.join(", ")}`);
  console.log(`interpNeeded: ${scan.interpNeeded ?? "none"}`);

  log("\n==> Resolving with nix-locate");
  const resolved = resolveLibs(scan);

  if (resolved.notFound.length > 0) {
    console.error(`Error: unresolved: ${resolved.notFound.join(", ")}`);
    process.exit(1);
  }

  log("\n==> Building packages");
  const build = buildPackages(resolved);

  for (const [attr, sp] of build.attrToStorePath) {
    console.log(`${attr} -> ${sp}`);
  }

  log("\n==> Finding interpreter");
  const interp = findInterpreter(resolved, build);
  if (interp) {
    console.log(`interpreter: ${interp.path}`);
  } else {
    console.error("Error: could not find interpreter");
    process.exit(1);
  }
}
