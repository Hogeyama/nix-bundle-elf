#!/usr/bin/env bun
// Unified CLI entry point for nix-bundle-elf.
// Usage:
//   cli.ts rpath [options] <binary>
//   cli.ts preload [options] <binary>

import { bundlePreload } from "./commands/bundle-preload.ts";
import { bundleRpath } from "./commands/bundle-rpath.ts";
import { bundleScript } from "./commands/bundle-script.ts";

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
  case "script":
    bundleScript(rest);
    break;
  default: {
    const prog = "nix-bundle-elf";
    console.error(`Usage: ${prog} <command> [options] <binary|script>

Bundle ELF binaries with all dependencies into a self-contained package.

Commands:
  rpath    Bundle a single binary using RPATH rewriting (recommended)
  preload  Bundle a single binary using LD_PRELOAD
  script   Bundle a shell script with multiple ELF binaries

Run '${prog} <command> --help' for command-specific options.`);
    process.exit(1);
  }
}
