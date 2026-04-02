#!/usr/bin/env bun
// Unified CLI entry point for nix-bundle-elf.
// Usage:
//   cli.ts rpath [options] <binary>
//   cli.ts preload [options] <binary>

import { bundlePreload } from "./commands/bundle-preload.ts";
import { bundleRpath } from "./commands/bundle-rpath.ts";

const args = process.argv.slice(2);
const command = args[0];
const rest = args.slice(1);

switch (command) {
  case "rpath":
    bundleRpath(rest);
    break;
  case "preload":
    bundlePreload(rest);
    break;
  default: {
    const prog = "nix-bundle-elf";
    console.error(`Usage: ${prog} <command> [options] <binary>

Bundle an ELF binary with all its dependencies into a self-contained package.

Commands:
  rpath    Bundle using RPATH rewriting (recommended)
  preload  Bundle using LD_PRELOAD

Run '${prog} <command> --help' for command-specific options.`);
    process.exit(1);
  }
}
