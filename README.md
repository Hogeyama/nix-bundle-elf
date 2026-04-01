# nix-bundle-elf

Bundle a dynamically-linked ELF into a self-extracting, runnable single file.

Two bundling strategies are available:

- **rpath** (default): Rewrites RPATH with `patchelf --set-rpath`. Simple and fast.
- **preload**: Uses `LD_PRELOAD` + `LD_LIBRARY_PATH` instead of rewriting RPATH.

Both strategies support Nix-built binaries and foreign (non-Nix) binaries.
Foreign binaries are auto-detected and their dependencies resolved via `nix-locate`.

## Demo

```bash
# Build a self-extracting executable derivation
nix build .#example-single-exe
./result -- --version
```

## Flake Usage

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nix-bundle-elf.url = "github:hogeyama/nix-bundle-elf";

  outputs = { self, nixpkgs, flake-utils, nix-bundle-elf, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        bundle = nix-bundle-elf.lib.${system};
      in {
        packages = {
          # rpath strategy (default)
          myapp = bundle.single-exe {
            inherit pkgs;
            name = "myapp";
            target = "${pkgs.curl}/bin/curl";
            extraFiles = { "conf/config.yaml" = ./config.yaml; };
            addFlags = [ "--config" "%ROOT/conf/config.yaml" ];
          };

          # preload strategy
          myapp-preload = bundle.single-exe {
            inherit pkgs;
            name = "myapp";
            target = "${pkgs.curl}/bin/curl";
            type = "preload";
            extraFiles = { "conf/config.yaml" = ./config.yaml; };
            addFlags = [ "--config" "%ROOT/conf/config.yaml" ];
          };
        };
      }
    );
}
```

### `lib.single-exe { pkgs; name; target; type ? "rpath"; extraFiles ? {}; addFlags ? []; }`

Builds a derivation that outputs a self-extracting executable.

- `name`: Output binary name.
- `target`: Path to the binary (e.g., `"${pkgs.foo}/bin/foo"`).
- `type` (optional): `"rpath"` (default) or `"preload"`.
- `extraFiles` (optional): Attrset of bundle-relative paths to source files.
- `addFlags` (optional): List of arguments injected before user-provided args.
  Use `%ROOT` to refer to the extracted bundle root, and `%%` for a literal `%`.

### `lib.aws-lambda-zip { pkgs; name; target; }`

Builds a Lambda-compatible zip with `bootstrap` and bundled libraries.

## CLI Usage

The repository's maintained CLI entry point is `src/cli.ts`:

```bash
bun run ./src/cli.ts <rpath|preload> [options] <binary>
```

### `bun run ./src/cli.ts rpath`

Bundles using RPATH rewriting. Supports both Nix and foreign binaries.

```bash
# Nix binary
bun run ./src/cli.ts rpath /nix/store/...-curl-*/bin/curl -o ./curl-bundled

# Foreign binary (auto-resolves deps via nix-locate)
bun run ./src/cli.ts rpath ./some-foreign-binary -o ./my-app

# Bundle an extra config file and inject runtime flags
bun run ./src/cli.ts rpath /nix/store/...-hl-*/bin/hl -o ./hl \
  --include ./config.yaml:conf/config.yaml \
  --add-flag '--config' \
  --add-flag '%ROOT/conf/config.yaml'

# Lambda zip
bun run ./src/cli.ts rpath /nix/store/...-curl-*/bin/curl --format lambda -o ./function.zip
```

### `bun run ./src/cli.ts preload`

Bundles using LD_PRELOAD instead of RPATH rewriting.

```bash
bun run ./src/cli.ts preload ~/.local/bin/copilot -o ./copilot
```

Both CLI commands accept repeatable `--include <src>:<dest>` and
`--add-flag <arg>` options. `--add-flag` arguments are inserted before
user arguments, `%ROOT` expands to the extracted bundle root at runtime,
and `%%` escapes a literal `%`.

### Running the generated executable

```bash
# Execute directly (extracts to temp dir)
./my-app -- --version

# Extract permanently
./my-app --extract ./my-app.bundle
./my-app.bundle/bin/my-app --version
```

## How It Works

### rpath strategy

1. Detects the interpreter with `patchelf --print-interpreter`.
2. First tries to traverse dependencies via `patchelf --print-needed` using
   RPATH/RUNPATH. If that is insufficient, resolves dependencies via
   `nix-locate` (unless `--no-nix-locate` is set).
3. Copies the interpreter and libraries to `lib/`, rewrites RUNPATH to `$ORIGIN`.
4. Sets the binary's RPATH to `$ORIGIN/../lib` and interpreter to a placeholder.
5. Creates a self-extracting script that patches the interpreter at runtime via `dd`.

### preload strategy

1. Same dependency resolution as rpath.
2. Copies libraries to `lib/`, rewrites their RUNPATH to `$ORIGIN`.
3. Sets only the interpreter to a placeholder (no `--set-rpath` on the binary).
4. Compiles `cleanup_env.so` for `LD_PRELOAD`, which:
   - Saves and removes `LD_LIBRARY_PATH`/`LD_PRELOAD` from environ on startup.
   - Restores them on self re-exec (Node.js SEA), strips them for child processes.
5. Creates a self-extracting script. Each invocation copies the binary to a temp dir,
   patches the interpreter copy via `dd`, and runs with `LD_LIBRARY_PATH` + `LD_PRELOAD`.

Both strategies preserve `/proc/self/exe` by executing the binary directly
(not via `ld-linux --argv0`).

## Testing

```bash
# All tests (flake checks + foreign binary tests)
nix develop -c just test
```

## Requirements

- Linux `x86_64` or `aarch64`.

## Limitations

- **Node.js SEA**: SEA binaries depend on `argv[0]` matching the original
  filename. The output file name (`-o`) must match the original binary name
  (e.g., `-o ./copilot`, not `-o ./copilot-bundled`).
- Dependency discovery for Nix binaries relies on RPATH/RUNPATH. `$ORIGIN`
  entries are not expanded during discovery.
- Foreign binary resolution requires a `nix-locate` database
  (`~/.cache/nix-index/files`).
- The produced artifact includes glibc and shared libs from your build
  environment. Portability is good in many cases, but not guaranteed if
  the target requires host facilities (e.g., NSS modules, CA certs).
