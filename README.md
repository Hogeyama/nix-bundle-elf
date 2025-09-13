# nix-bundle-elf

Bundle a dynamically-linked ELF into a self-extracting, runnable single file.

This project uses `patchelf` to collect the dynamic loader and shared libraries
reachable via RPATH/RUNPATH, rewrites RUNPATHs to be relative, and assembles the
result into a portable artifact.

## Demo

```bash
# Example: build a self-extracting executable derivation
nix build .#example-single-exe
./result -- --version
```

## Usage

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
        packages.myapp-bundle = bundle.single-exe {
          inherit pkgs;
          name = "myapp";
          target = "${pkgs.curl}/bin/curl";
        };
      }
    );
}
```

- `lib.single-exe { pkgs; name; target; }`
  - Builds a derivation that outputs a self-extracting executable named `name`.
  - `target` is a path-like string to the binary (e.g., `${pkgs.foo}/bin/foo`).

## Optional: CLI Usage

For quick local testing without flakes:

```bash
bash bundle.bash <target> --format exe [name]
```

- `target`: Path to the ELF binary to bundle.
- `--format`: Output format. Use `exe`.
- `name` (optional): Output name when `--format exe`. Defaults to `basename <target>`.
- `--help`: Prints usage.

Examples:

```bash
# self-contained executable
bash bundle.bash /nix/store/...-curl-*/bin/curl --format exe curl-bundled
./curl-bundled -- --version

# extract the payload to a directory instead of executing
./curl-bundled --extract ./curl.bundle
./curl.bundle/bin/curl --version
```

Notes for `exe` format:
- Running the generated file will extract to a temporary directory and execute.
- Use `--` to separate script flags from program flags: `./name -- --version`.
- Use `--extract <dir>` to materialize the payload. A wrapper is written to
  `<dir>/bin/<name>` that launches the original with the bundled loader/libs.

### Overriding libraries

You can override libraries by pointing `LD_LIBRARY_PATH` to
directories containing replacement `.so` files.

Examples:

```bash
# Without extraction
env LD_LIBRARY_PATH=/path/to/overrides ./myapp -- --version

# After --extract
./myapp --extract ./appdir
LD_LIBRARY_PATH=/path/to/overrides ./appdir/bin/myapp -- --version
```

## How It Works

- Detects the program interpreter with `patchelf --print-interpreter`.
- Traverses dependencies via `patchelf --print-needed` and locates them using
  RPATH/RUNPATH collected from visited objects (discovery only).
- Copies the interpreter and all located libraries to `out/lib/` and rewrites
  their RUNPATH to `$ORIGIN`.
- Copies the original binary to `out/orig/<name>` and sets its RUNPATH to
  `$ORIGIN/../lib`.
- Creates a self-extracting script that appends a tarball of `out/` and, when
  run, extracts to a temp dir and executes via the bundled interpreter.

## Requirements

- Linux `x86_64` or `aarch64`.

## Limitations & Tips

- Dependency discovery relies on embedded RPATH/RUNPATH of the target and its
  libraries. System default search paths and `LD_LIBRARY_PATH` are not used at
  bundle time. At runtime, `LD_LIBRARY_PATH` is honored.
- Requires binaries that carry explicit RUNPATHs for reliable discovery during
  bundling (typically Nix-built). Bundle time does not consult `LD_LIBRARY_PATH`
  or default system paths like `/lib` or `/usr/lib`. Also, `$ORIGIN` entries in
  RPATH/RUNPATH are not expanded during dependency discovery.
- The produced artifact includes the glibc loader and shared libs from your build
  environment. Portability across distros/hosts is good in many cases, but not
  guaranteed if the target requires host facilities (e.g. NSS modules, CA certs).
