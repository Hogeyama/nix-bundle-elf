test_dir := ".test"
foreign_bin := "test-foreign/test-foreign"

# Run all checks and foreign binary tests
test: check test-bun test-rpath-foreign test-preload-foreign test-preload-foreign-dlopen test-preload-foreign-self-exec test-flake

# Build the foreign test binary (C binary with stripped RPATH)
build-foreign:
    @if [ ! -f {{ foreign_bin }} ]; then \
        echo "==> Building foreign test binary..."; \
        gcc -o {{ foreign_bin }} test-foreign/test-foreign.c -ldl; \
        patchelf --set-rpath "" {{ foreign_bin }}; \
    else \
        echo "==> Foreign test binary already built"; \
    fi

# Test bundle-rpath with a foreign binary
test-rpath-foreign: build-foreign
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing bundle-rpath with foreign binary"
    rm -f {{ test_dir }}/foreign-rpath
    bun run ./src/cli.ts rpath --format exe -o {{ test_dir }}/foreign-rpath {{ foreign_bin }}
    echo "--- execute mode ---"
    output=$({{ test_dir }}/foreign-rpath -- --version)
    echo "$output"
    echo "$output" | grep -q "test-foreign 1.0"
    echo "--- extract mode ---"
    rm -rf {{ test_dir }}/foreign-rpath-extracted
    {{ test_dir }}/foreign-rpath --extract {{ test_dir }}/foreign-rpath-extracted
    output=$({{ test_dir }}/foreign-rpath-extracted/bin/foreign-rpath --version)
    echo "$output"
    echo "$output" | grep -q "test-foreign 1.0"
    echo "PASS: test-rpath-foreign"

# Test bundle-preload with a foreign binary
test-preload-foreign: build-foreign
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing bundle-preload with foreign binary"
    rm -f {{ test_dir }}/foreign-preload
    bun run ./src/cli.ts preload -o {{ test_dir }}/foreign-preload {{ foreign_bin }}
    echo "--- execute mode ---"
    output=$({{ test_dir }}/foreign-preload -- --version)
    echo "$output"
    echo "$output" | grep -q "test-foreign 1.0"
    echo "--- extract mode ---"
    rm -rf {{ test_dir }}/foreign-preload-extracted
    {{ test_dir }}/foreign-preload --extract {{ test_dir }}/foreign-preload-extracted
    output=$({{ test_dir }}/foreign-preload-extracted/bin/foreign-preload --version)
    echo "$output"
    echo "$output" | grep -q "test-foreign 1.0"
    echo "PASS: test-preload-foreign"

# Test that dlopen works in the bundled binary (preload + extra-lib)
test-preload-foreign-dlopen: build-foreign
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing dlopen in bundled foreign binary"
    rm -f {{ test_dir }}/foreign-dlopen
    bun run ./src/cli.ts preload --extra-lib libz.so.1 -o {{ test_dir }}/foreign-dlopen {{ foreign_bin }}
    echo "--- execute mode ---"
    output=$({{ test_dir }}/foreign-dlopen --)
    echo "$output"
    echo "$output" | grep -q "dlopen: zlib"
    echo "--- extract mode ---"
    rm -rf {{ test_dir }}/foreign-dlopen-extracted
    {{ test_dir }}/foreign-dlopen --extract {{ test_dir }}/foreign-dlopen-extracted
    output=$({{ test_dir }}/foreign-dlopen-extracted/bin/foreign-dlopen)
    echo "$output"
    echo "$output" | grep -q "dlopen: zlib"
    echo "PASS: test-preload-foreign-dlopen"

# Test that self-exec works in the bundled binary
test-preload-foreign-self-exec: build-foreign
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing self-exec in bundled foreign binary"
    rm -f {{ test_dir }}/foreign-selfexec
    bun run ./src/cli.ts preload -o {{ test_dir }}/foreign-selfexec {{ foreign_bin }}
    echo "--- execute mode ---"
    output=$({{ test_dir }}/foreign-selfexec -- --self-exec)
    echo "$output"
    echo "$output" | grep -q "self-exec: re-executing"
    echo "$output" | grep -q "test-foreign 1.0"
    echo "--- extract mode ---"
    rm -rf {{ test_dir }}/foreign-selfexec-extracted
    {{ test_dir }}/foreign-selfexec --extract {{ test_dir }}/foreign-selfexec-extracted
    output=$({{ test_dir }}/foreign-selfexec-extracted/bin/foreign-selfexec --self-exec)
    echo "$output"
    echo "$output" | grep -q "self-exec: re-executing"
    echo "$output" | grep -q "test-foreign 1.0"
    echo "PASS: test-preload-foreign-self-exec"

test-bun:
    bun test

test-flake:
    #!/usr/bin/env bash
    nix flake check

# Format all source files
format:
    bun fmt

# Lint all source files
lint:
    bun lint

# Type check TypeScript
typecheck:
    bun typecheck

# Run lint + typecheck
check:
    bun check

# Clean test artifacts
clean:
    rm -rf {{ test_dir }}
    rm -f {{ foreign_bin }}
