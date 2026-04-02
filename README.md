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

Build the CLI with `nix build .#default`, then:

```bash
nix-bundle-elf <rpath|preload> [options] <binary>
```

### `nix-bundle-elf rpath`

Bundles using RPATH rewriting. Supports both Nix and foreign binaries.

```bash
# Nix binary
nix-bundle-elf rpath /nix/store/...-curl-*/bin/curl -o ./curl-bundled

# Foreign binary (auto-resolves deps via nix-locate)
nix-bundle-elf rpath ./some-foreign-binary -o ./my-app

# Bundle an extra config file and inject runtime flags
nix-bundle-elf rpath /nix/store/...-hl-*/bin/hl -o ./hl \
  --include ./config.yaml:conf/config.yaml \
  --add-flag '--config' \
  --add-flag '%ROOT/conf/config.yaml'

# Lambda zip
nix-bundle-elf rpath /nix/store/...-curl-*/bin/curl --format lambda -o ./function.zip
```

### `nix-bundle-elf preload`

Bundles using LD_PRELOAD instead of RPATH rewriting.

```bash
nix-bundle-elf preload ~/.local/bin/copilot -o ./copilot

# Bundle extra libraries needed by indirect dlopen dependencies
nix-bundle-elf preload --extra-lib libutil.so.1 ~/.local/bin/copilot -o ./copilot
```

Both CLI commands accept repeatable `--include <src>:<dest>` and
`--add-flag <arg>` options. `--add-flag` arguments are inserted before
user arguments, `%ROOT` expands to the extracted bundle root at runtime,
and `%%` escapes a literal `%`.

The `preload` command additionally accepts repeatable `--extra-lib <soname>`
to bundle libraries that cannot be discovered by NEEDED/RPATH traversal
(e.g. libraries loaded at runtime via `dlopen`).
The soname is resolved through the same pipeline as regular NEEDED entries.

### nix-index database

Foreign binary bundling requires a `nix-locate` database. The database is
automatically downloaded from
[nix-community/nix-index-database](https://github.com/nix-community/nix-index-database)
releases. The nixpkgs revision used for `nix build` is derived from the same
release tag's `flake.lock`, ensuring the database and built packages are always
in sync.

Use **`--nix-index-db-ref <tag>`** to specify a different release tag
(e.g. `--nix-index-db-ref 2026-03-15-045700`).

This means foreign binary bundling works out of the box in CI environments
(e.g. GitHub Actions) without any extra setup — the database is fetched on
first use.

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
   - Restores them on self re-exec, strips them for child processes.
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

- Dependency discovery for Nix binaries relies on RPATH/RUNPATH. `$ORIGIN`
  entries are not expanded during discovery.
- Foreign binary resolution requires a `nix-locate` database (auto-downloaded
  if not present; see [nix-index database](#nix-index-database)).
- The produced artifact includes glibc and shared libs from your build
  environment. Portability is good in many cases, but not guaranteed if
  the target requires host facilities (e.g., NSS modules, CA certs).
