#!/usr/bin/env bun
// Type-safe wrapper around the patchelf command.
//
// Usage as CLI (for testing):
//   patchelf.ts <binary>
// Prints interpreter, needed libs, and rpath.

import { resolveTool } from "./resolve-tool.ts";

let patchelfPath: string | null = null;

function getPatchelf(): string {
  if (patchelfPath === null) {
    patchelfPath = resolveTool("", "patchelf", "patchelf");
  }
  return patchelfPath;
}

/** Override the patchelf binary path (useful when the caller already resolved it). */
export function setPatchelfPath(path: string): void {
  patchelfPath = path;
}

function run(args: string[]): string {
  const result = Bun.spawnSync([getPatchelf(), ...args]);
  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`patchelf ${args.join(" ")} failed (exit ${result.exitCode}): ${stderr}`);
  }
  return result.stdout.toString().trim();
}

function runMut(args: string[]): void {
  const result = Bun.spawnSync([getPatchelf(), ...args]);
  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`patchelf ${args.join(" ")} failed (exit ${result.exitCode}): ${stderr}`);
  }
}

/** Get the ELF interpreter (e.g. /nix/store/.../lib/ld-linux-x86-64.so.2). */
export function printInterpreter(binary: string): string {
  return run(["--print-interpreter", binary]);
}

/** Get NEEDED library sonames (e.g. ["libc.so.6", "libm.so.6"]). */
export function printNeeded(binary: string): string[] {
  const out = run(["--print-needed", binary]);
  if (out === "") return [];
  return out.split("\n").filter((s) => s !== "");
}

/** Get RPATH/RUNPATH entries as an array of directory paths. */
export function printRpath(binary: string): string[] {
  const out = run(["--print-rpath", binary]);
  if (out === "") return [];
  return out.split(":");
}

/** Set the ELF interpreter. */
export function setInterpreter(binary: string, interpreter: string): void {
  runMut(["--set-interpreter", interpreter, binary]);
}

/** Set RPATH/RUNPATH. */
export function setRpath(binary: string, rpath: string): void {
  runMut(["--set-rpath", rpath, binary]);
}

// CLI mode: print all metadata for a given binary
if (import.meta.main) {
  const binary = process.argv[2];
  if (!binary) {
    console.error("Usage: patchelf.ts <binary>");
    process.exit(1);
  }

  console.log(`interpreter: ${printInterpreter(binary)}`);
  console.log(`needed: ${printNeeded(binary).join(", ")}`);
  console.log(`rpath: ${printRpath(binary).join(":")}`);
}
