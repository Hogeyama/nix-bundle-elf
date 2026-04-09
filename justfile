test_dir := ".test"
copilot_url := "https://github.com/github/copilot-cli/releases/download/v1.0.14/copilot-linux-x64.tar.gz"

# Run all checks and foreign binary tests
test: check test-bun test-rpath-foreign test-preload-foreign test-preload-sea test-flake

# Download copilot-cli (Node.js SEA, foreign ELF with several deps)
download-copilot:
    mkdir -p {{ test_dir }}/bin
    @if [ ! -f {{ test_dir }}/bin/copilot ]; then \
        echo "==> Downloading copilot-cli..."; \
        curl -sL {{ copilot_url }} | tar xz -C {{ test_dir }}/bin; \
    else \
        echo "==> copilot-cli already downloaded"; \
    fi

# Test bundle-rpath with a foreign binary (copilot-cli)
test-rpath-foreign: download-copilot
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing bundle-rpath with foreign binary"
    rm -f {{ test_dir }}/copilot-rpath
    bun run ./src/cli.ts rpath --format exe -o {{ test_dir }}/copilot-rpath {{ test_dir }}/bin/copilot
    echo "--- execute mode ---"
    output=$({{ test_dir }}/copilot-rpath -- --version 2>&1) || true
    echo "$output"
    echo "$output" | grep -qi "copilot"
    echo "--- extract mode ---"
    rm -rf {{ test_dir }}/copilot-rpath-extracted
    {{ test_dir }}/copilot-rpath --extract {{ test_dir }}/copilot-rpath-extracted
    output=$({{ test_dir }}/copilot-rpath-extracted/bin/copilot-rpath --version 2>&1) || true
    echo "$output"
    echo "$output" | grep -qi "copilot"
    echo "PASS: test-rpath-foreign"

# Test bundle-preload with a foreign binary (copilot-cli)
test-preload-foreign: download-copilot
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing bundle-preload with foreign binary"
    rm -f {{ test_dir }}/copilot-preload
    bun run ./src/cli.ts preload -o {{ test_dir }}/copilot-preload {{ test_dir }}/bin/copilot
    echo "--- execute mode ---"
    output=$({{ test_dir }}/copilot-preload -- --version 2>&1) || true
    echo "$output"
    echo "$output" | grep -qi "copilot"
    echo "--- extract mode ---"
    rm -rf {{ test_dir }}/copilot-preload-extracted
    {{ test_dir }}/copilot-preload --extract {{ test_dir }}/copilot-preload-extracted
    output=$({{ test_dir }}/copilot-preload-extracted/bin/copilot-preload --version 2>&1) || true
    echo "$output"
    echo "$output" | grep -qi "copilot"
    echo "PASS: test-preload-foreign"

# Test that preload preserves Node.js SEA (rpath corrupts NOTE segments)

# The rpath version may fail or produce a broken binary, while preload works.
test-preload-sea: download-copilot
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Testing that preload preserves Node.js SEA NOTE segments"

    # Preload version: should work because it doesn't use --set-rpath
    rm -f {{ test_dir }}/copilot-sea-preload
    bun run ./src/cli.ts preload -o {{ test_dir }}/copilot-sea-preload {{ test_dir }}/bin/copilot
    echo "--- preload: extract and check ---"
    rm -rf {{ test_dir }}/sea-preload-extracted
    {{ test_dir }}/copilot-sea-preload --extract {{ test_dir }}/sea-preload-extracted

    # The extracted binary should NOT have RPATH set on it (preload uses LD_LIBRARY_PATH)
    rpath=$(patchelf --print-rpath {{ test_dir }}/sea-preload-extracted/orig/copilot-sea-preload 2>/dev/null || echo "")
    echo "preload orig RPATH: '$rpath'"
    # RPATH should be empty (no --set-rpath was applied)
    [ -z "$rpath" ]

    # Should run correctly
    output=$({{ test_dir }}/sea-preload-extracted/bin/copilot-sea-preload --version 2>&1) || true
    echo "$output"
    echo "$output" | grep -qi "copilot"
    echo "PASS: test-preload-sea (NOTE segments preserved)"

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
