// Common logic shared between bundle-rpath and bundle-preload.

import {
  chmodSync,
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { basename, dirname, isAbsolute, relative, resolve } from "node:path";
import { gatherDeps } from "./gather-nix-deps.ts";
import { setNixLocateDbDir } from "./nix.ts";
import { resolveNixIndexDb } from "./nix-index-db.ts";
import * as patchelf from "./patchelf.ts";
import { buildPackages, findInterpreter, resolveLibs, scanNeeded } from "./resolve-foreign-deps.ts";
import type { BundleConfig } from "./types.ts";

function log(msg: string): void {
  console.error(msg);
}

export const INTERP_PLACEHOLDER_LEN = 256;
export const INTERP_PLACEHOLDER_TAG = "NIXBUNDLEELF_INTERP_PLACEHOLDER";

/** Build the 256-byte interpreter placeholder string. */
export function makeInterpPlaceholder(): string {
  let placeholder = `/${INTERP_PLACEHOLDER_TAG}`;
  while (placeholder.length < INTERP_PLACEHOLDER_LEN) {
    placeholder += "/";
  }
  return placeholder.slice(0, INTERP_PLACEHOLDER_LEN);
}

function printUsage(supportsFormat: boolean): void {
  const prog = "nix-bundle-elf";
  const formatLine = supportsFormat
    ? "\n  --format <exe|lambda>        Output format (default: exe)"
    : "";
  console.error(`Usage: ${prog} <rpath|preload> [options] <binary>

Options:
  -o, --output <path>          Output path (default: ./<binary-name>)${formatLine}
  --include <src>:<dest>       Include a file or directory in the bundle (repeatable)
  --extra-lib <path>           Add an extra shared library to the bundle (repeatable)
  --add-flag <flag>            Pass an additional flag to nix build (repeatable)
  --no-nix-locate              Disable nix-locate for dependency resolution
  --nix-index-db-ref <ref>     Git ref for nix-index-database
  -h, --help                   Show this help message`);
}

/** Parse CLI arguments into a BundleConfig. */
export function parseArgs(argv: string[], supportsFormat: boolean): BundleConfig {
  const config: BundleConfig = {
    target: "",
    output: "",
    format: "exe",
    useNixLocate: true,
    addFlags: [],
    includes: [],
    extraLibs: [],
  };

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        printUsage(supportsFormat);
        process.exit(0);
        break;
      case "-o":
      case "--output":
        config.output = argv[++i] ?? "";
        if (!config.output) throw new Error("--output requires an argument");
        break;
      case "--format":
        if (!supportsFormat) throw new Error("--format is not supported for this command");
        {
          const fmt = argv[++i];
          if (fmt !== "exe" && fmt !== "lambda") throw new Error(`invalid format: ${fmt}`);
          config.format = fmt;
        }
        break;
      case "--no-nix-locate":
        config.useNixLocate = false;
        break;
      case "--add-flag":
        {
          const flag = argv[++i];
          if (flag === undefined) throw new Error("--add-flag requires an argument");
          config.addFlags.push(flag);
        }
        break;
      case "--include":
        {
          const inc = argv[++i];
          if (inc === undefined) throw new Error("--include requires an argument");
          const colonIdx = inc.indexOf(":");
          if (colonIdx === -1) throw new Error(`--include format must be src:dest, got: ${inc}`);
          config.includes.push({ src: inc.slice(0, colonIdx), dest: inc.slice(colonIdx + 1) });
        }
        break;
      case "--extra-lib":
        {
          const lib = argv[++i];
          if (lib === undefined) throw new Error("--extra-lib requires an argument");
          config.extraLibs.push(lib);
        }
        break;
      case "--nix-index-db-ref":
        config.nixIndexDbRef = argv[++i] ?? "";
        if (!config.nixIndexDbRef) throw new Error("--nix-index-db-ref requires an argument");
        break;
      default:
        if (arg.startsWith("-")) throw new Error(`unknown option: ${arg}`);
        if (config.target) throw new Error(`unexpected argument: ${arg}`);
        config.target = arg;
    }
    i++;
  }

  if (!config.target) throw new Error("target binary is required");

  config.target = realpathSync(config.target);
  if (!existsSync(config.target)) throw new Error(`target does not exist: ${config.target}`);

  for (const include of config.includes) {
    include.src = realpathSync(include.src);
    const st = statSync(include.src);
    if (!st.isFile() && !st.isDirectory()) {
      throw new Error(`--include source must be a file or directory: ${include.src}`);
    }
    if (include.dest === "") {
      throw new Error("--include destination must not be empty");
    }
  }

  if (!config.output) {
    config.output = resolve(process.cwd(), basename(config.target));
  }

  const name = basename(config.output);
  config.output = resolve(dirname(config.output), name);

  if (existsSync(config.output)) {
    throw new Error(
      `Output path '${config.output}' already exists. Use -o to specify a different output path, or remove the existing file first.`,
    );
  }

  return config;
}

export interface GatheredDeps {
  /** Absolute paths to library files. */
  libs: string[];
  /** Interpreter basename (e.g. ld-linux-x86-64.so.2). */
  interpreterBasename: string;
  /** Full path to interpreter. */
  interpreterPath: string;
  /** The target binary path (may differ from config.target if patched). */
  effectiveTarget: string;
}

/**
 * Gather all shared library dependencies for the target binary.
 * First tries RPATH traversal; falls back to nix-locate if needed.
 */
export function gatherAllDeps(config: BundleConfig, tmpdir: string): GatheredDeps {
  log("==> Gathering dependencies via RPATH");

  let target = config.target;
  let interpreter = patchelf.printInterpreter(target);
  let interpreterBasename = basename(interpreter);

  const result = gatherDeps(target, interpreterBasename, config.extraLibs);

  if (result === null) {
    log("  RPATH-only resolution was insufficient");
    if (!config.useNixLocate) {
      throw new Error(
        "dependency resolution via RPATH/RUNPATH was insufficient. " +
          "Use nix-locate to resolve dependencies (remove --no-nix-locate).",
      );
    }

    // Resolve nix-index database and nixpkgs revision
    const dbInfo = resolveNixIndexDb(config.nixIndexDbRef);
    setNixLocateDbDir(dbInfo.dbDir);

    // Fall back to nix-locate
    target = patchForeign(config.target, tmpdir, config.extraLibs, dbInfo.nixpkgsRev);
    interpreter = patchelf.printInterpreter(target);
    interpreterBasename = basename(interpreter);

    const retryResult = gatherDeps(target, interpreterBasename, config.extraLibs);
    if (retryResult === null) {
      throw new Error("dependency resolution failed even after nix-locate patching");
    }

    return {
      libs: retryResult.libs,
      interpreterBasename,
      interpreterPath: interpreter,
      effectiveTarget: target,
    };
  }

  return {
    libs: result.libs,
    interpreterBasename,
    interpreterPath: interpreter,
    effectiveTarget: target,
  };
}

/** Patch a foreign (non-Nix) binary to use /nix/store libraries. */
function patchForeign(
  target: string,
  tmpdir: string,
  extraSonames: string[] = [],
  nixpkgsRev?: string,
): string {
  log("==> Resolving unresolved dependencies with nix-locate");
  log(`==> Scanning ${target}`);

  const scan = scanNeeded(target);
  scan.needed.push(...extraSonames);
  if (scan.needed.length === 0 && !scan.interpNeeded) {
    throw new Error("no dynamic dependencies found. Is this a static binary?");
  }

  log("==> Resolving libraries with nix-locate");
  const resolved = resolveLibs(scan);
  if (resolved.notFound.length > 0) {
    throw new Error(`could not find packages for: ${resolved.notFound.join(" ")}`);
  }

  log("==> Building packages");
  const build = buildPackages(resolved, nixpkgsRev);

  const interpInfo = findInterpreter(resolved, build);
  if (!interpInfo) {
    throw new Error("could not find interpreter (ld-linux)");
  }

  // Collect RPATH entries from store paths
  const rpathEntries: string[] = [];
  for (const sp of build.attrToStorePath.values()) {
    const libDir = `${sp}/lib`;
    if (existsSync(libDir)) rpathEntries.push(libDir);
  }
  if (interpInfo.extraStorePath) {
    const libDir = `${interpInfo.extraStorePath}/lib`;
    if (existsSync(libDir)) rpathEntries.push(libDir);
  }
  const rpath = rpathEntries.join(":");

  // Patch a copy of the binary
  const patched = `${tmpdir}/patched_${basename(target)}`;
  copyFileSync(target, patched);
  chmodSync(patched, 0o755);
  patchelf.setInterpreter(patched, interpInfo.path);
  patchelf.setRpath(patched, rpath);
  chmodSync(patched, 0o555);

  log("==> Patched to use /nix/store paths, proceeding with bundling");
  return patched;
}

/** Copy --include files/directories into the bundle output directory. */
export function copyIncludes(includes: Array<{ src: string; dest: string }>, outDir: string): void {
  const bundleRoot = resolve(outDir);
  for (const { src, dest } of includes) {
    const destPath = resolve(bundleRoot, dest);
    const rel = relative(bundleRoot, destPath);
    if (rel.startsWith("..") || isAbsolute(rel)) {
      throw new Error(`--include destination escapes bundle root: ${dest}`);
    }
    if (statSync(src).isDirectory()) {
      cpSync(src, destPath, { recursive: true });
    } else {
      mkdirSync(dirname(destPath), { recursive: true });
      copyFileSync(src, destPath);
    }
  }
}

/**
 * Copy libraries to out/lib/, patch their RUNPATH to $ORIGIN, and copy interpreter.
 */
export function copyAndPatchLibs(libs: string[], interpreterPath: string, outDir: string): void {
  const libDir = `${outDir}/lib`;
  mkdirSync(libDir, { recursive: true });

  // Copy interpreter
  copyFileSync(interpreterPath, `${libDir}/${basename(interpreterPath)}`);

  log("==> Bundling");
  log("  Patching library RUNPATH");

  for (const libfile of libs) {
    const libb = basename(libfile);
    const dest = `${libDir}/${libb}`;
    copyFileSync(libfile, dest);
    chmodSync(dest, 0o755);
    patchelf.setRpath(dest, "$ORIGIN");
    chmodSync(dest, 0o555);
  }
}

/**
 * Set the interpreter placeholder on a binary and return the byte offset.
 * The binary must be writable.
 */
export function setPlaceholderInterpreter(binaryPath: string): number {
  const placeholder = makeInterpPlaceholder();
  patchelf.setInterpreter(binaryPath, placeholder);

  // Find the byte offset of the placeholder tag in the binary.
  // Use grep -boa for simplicity (same approach as bash version).
  const grepResult = Bun.spawnSync(["grep", "-c", INTERP_PLACEHOLDER_TAG, binaryPath]);
  const matchCount = Number.parseInt(grepResult.stdout.toString().trim() || "0", 10);
  if (matchCount !== 1) {
    throw new Error(`interpreter placeholder found ${matchCount} times (expected 1)`);
  }

  const offsetResult = Bun.spawnSync(["grep", "-boa", INTERP_PLACEHOLDER_TAG, binaryPath]);
  const offsetLine = offsetResult.stdout.toString().trim().split("\n")[0];
  const offset = Number.parseInt(offsetLine.split(":")[0], 10);
  return offset - 1; // account for leading "/"
}
