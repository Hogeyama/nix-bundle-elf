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
  default:
    console.error(`Usage: cli.ts <rpath|preload> [options] <binary>`);
    console.error("");
    console.error("Commands:");
    console.error("  rpath    Bundle using RPATH rewriting");
    console.error("  preload  Bundle using LD_PRELOAD");
    process.exit(1);
}
