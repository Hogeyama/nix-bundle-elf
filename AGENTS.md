# AGENTS.md

## Project overview

nix-bundle-elf bundles ELF binaries with their shared library dependencies into
self-contained executables. It supports two bundling strategies: `rpath` and
`preload`. Non-Nix binaries are supported via `nix-locate` for automatic
dependency resolution.

## Tech stack

- Runtime: Bun
- Language: TypeScript (strict)
- Formatter/Linter: Biome
- Build: `nix build .#default` (compiles `cli.ts` into a standalone binary)

## Scripts

- `bun run fmt` — format code (biome check --write)
- `bun run lint` — lint code (biome check)
- `bun run typecheck` — type check (tsc --noEmit)
- `bun run check` — lint + typecheck

## Code structure

- `src/cli.ts` — CLI entry point, dispatches to `bundleRpath` or `bundlePreload`
- `src/lib/bundle-common.ts` — shared logic: argument parsing, dependency gathering, library patching
- `src/lib/bundle-rpath.ts` — rpath bundling strategy
- `src/lib/bundle-preload.ts` — LD_PRELOAD bundling strategy
- `src/lib/gather-nix-deps.ts` — BFS traversal of NEEDED/RPATH to collect shared libraries
- `src/lib/resolve-foreign-deps.ts` — resolve non-Nix dependencies via nix-locate
- `src/lib/nix-index-db.ts` — download nix-index database and resolve nixpkgs revision
- `src/lib/nix.ts` — wrappers around nix CLI commands (nix build, nix-locate, nix-store)
- `src/lib/patchelf.ts` — wrappers around patchelf
- `src/lib/shell-template.ts` — shell script templates for self-extracting bundles
- `src/lib/types.ts` — shared type definitions

## Conventions

- Always run `bun run check` before committing
- Biome config: 2-space indent, 100 char line width
- Source files are under `src/` with `.ts` extension
