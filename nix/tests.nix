{ pkgs, single-exe, aws-lambda-zip, bundle-script }:

let
  test-single-exe = single-exe {
    name = "curl";
    target = "${pkgs.curl}/bin/curl";
  };
  test-single-exe-preload = single-exe {
    name = "curl";
    target = "${pkgs.curl}/bin/curl";
    type = "preload";
  };
  test-lambda-zip = aws-lambda-zip {
    name = "curl";
    target = "${pkgs.curl}/bin/curl";
  };
  test-include-file = pkgs.writeText "test-include" "BUNDLED_CONTENT_OK";
  test-add-flag-rpath = single-exe {
    name = "cat";
    target = "${pkgs.coreutils}/bin/cat";
    extraFiles = { "test/foo" = test-include-file; };
    addFlags = [ "%ROOT/test/foo" ];
  };
  test-add-flag-preload = single-exe {
    name = "cat";
    target = "${pkgs.coreutils}/bin/cat";
    type = "preload";
    extraFiles = { "test/foo" = test-include-file; };
    addFlags = [ "%ROOT/test/foo" ];
  };
  test-add-flag-preload-space = single-exe {
    name = "expr";
    target = "${pkgs.coreutils}/bin/expr";
    type = "preload";
    addFlags = [ "length" "foo bar" ];
  };
  test-env-rpath = single-exe {
    name = "printenv";
    target = "${pkgs.coreutils}/bin/printenv";
    env = [
      { key = "NIX_BUNDLE_TEST_SET"; action = "replace"; value = "hello_world"; }
      { key = "NIX_BUNDLE_TEST_PREFIX"; action = "prepend"; separator = ":"; value = "/new/prefix"; }
      { key = "NIX_BUNDLE_TEST_SUFFIX"; action = "append"; separator = ":"; value = "/new/suffix"; }
    ];
  };
  test-env-preload = single-exe {
    name = "printenv";
    target = "${pkgs.coreutils}/bin/printenv";
    type = "preload";
    env = [
      { key = "NIX_BUNDLE_TEST_SET"; action = "replace"; value = "hello_world"; }
      { key = "NIX_BUNDLE_TEST_PREFIX"; action = "prepend"; separator = ":"; value = "/new/prefix"; }
      { key = "NIX_BUNDLE_TEST_SUFFIX"; action = "append"; separator = ":"; value = "/new/suffix"; }
    ];
  };

  # script bundle test fixtures
  test-script-entry-single = pkgs.writeScript "test-entry-single" ''
    #!/bin/sh
    echo "SCRIPT_START"
    cat --version | head -1
    echo "SCRIPT_END"
  '';
  test-bundle-script-single = bundle-script {
    name = "test-script-single";
    script = test-script-entry-single;
    binaries = [
      { name = "cat"; target = "${pkgs.coreutils}/bin/cat"; }
    ];
  };
  test-script-entry-multi = pkgs.writeScript "test-entry-multi" ''
    #!/bin/sh
    echo "MULTI_START"
    curl --version | head -1
    cat --version | head -1
    echo "MULTI_END"
  '';
  test-bundle-script-multi = bundle-script {
    name = "test-script-multi";
    script = test-script-entry-multi;
    binaries = [
      { name = "curl"; target = "${pkgs.curl}/bin/curl"; }
      { name = "cat"; target = "${pkgs.coreutils}/bin/cat"; }
    ];
  };
  test-bundle-script-multi-preload = bundle-script {
    name = "test-script-multi-preload";
    script = test-script-entry-multi;
    type = "preload";
    binaries = [
      { name = "curl"; target = "${pkgs.curl}/bin/curl"; }
      { name = "cat"; target = "${pkgs.coreutils}/bin/cat"; }
    ];
  };
in
{
  # curl --version で transitive な依存を含むバンドルが動作することを確認
  single-exe-run = pkgs.runCommand "check-single-exe-run"
    { }
    ''
      output=$(${test-single-exe} -- --version)
      echo "$output"
      echo "$output" | grep -q "curl"
      echo "$output" | grep -q "libcurl"
      echo "PASS: single-exe-run"
      mkdir -p $out
    '';

  # --extract で展開し、transitive 依存が正しく収集されていることを確認
  single-exe-extract = pkgs.runCommand "check-single-exe-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-single-exe} --extract "$extractdir"

      # ラッパースクリプトの存在と実行
      test -x "$extractdir/bin/curl"
      output=$("$extractdir/bin/curl" --version)
      echo "$output"
      echo "$output" | grep -q "curl"

      # オリジナルバイナリの存在
      test -f "$extractdir/orig/curl"

      # transitive な依存ライブラリの存在確認
      # curl -> libcurl -> libssl/libcrypto, libz
      ls "$extractdir/lib/"
      test -n "$(find "$extractdir/lib" -name "libcurl.so*" -print -quit)"
      test -n "$(find "$extractdir/lib" -name "libz.so*" -o -name "libzstd.so*" -print -quit)"

      # .so の数が十分あること（curl は通常 10+ の依存を持つ）
      so_count=$(find "$extractdir/lib" -name "*.so*" | wc -l)
      echo "Found $so_count shared libraries"
      [ "$so_count" -ge 5 ]

      echo "PASS: single-exe-extract"
      mkdir -p $out
    '';

  # 展開後のバイナリ・ライブラリの RPATH が正しく設定されていることを確認
  single-exe-extract-rpath = pkgs.runCommand "check-single-exe-extract-rpath"
    { nativeBuildInputs = [ pkgs.patchelf ]; }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-single-exe} --extract "$extractdir"

      # orig/curl の RUNPATH が $ORIGIN/../lib であること
      rpath=$(patchelf --print-rpath "$extractdir/orig/curl")
      echo "orig/curl RPATH: $rpath"
      echo "$rpath" | grep -q "\$ORIGIN/../lib"

      # lib/ 内の各 .so の RUNPATH が $ORIGIN であること
      # ただし ld-linux（インタープリタ）は除く
      for lib in "$extractdir/lib/"*.so*; do
        libb=$(basename "$lib")
        case "$libb" in ld-linux*) continue ;; esac
        rpath=$(patchelf --print-rpath "$lib")
        echo "$libb RPATH: $rpath"
        echo "$rpath" | grep -q "\$ORIGIN"
      done

      echo "PASS: single-exe-extract-rpath"
      mkdir -p $out
    '';

  # preload 版: curl --version で動作確認
  single-exe-preload-run = pkgs.runCommand "check-single-exe-preload-run"
    { }
    ''
      output=$(${test-single-exe-preload} -- --version)
      echo "$output"
      echo "$output" | grep -q "curl"
      echo "$output" | grep -q "libcurl"
      echo "PASS: single-exe-preload-run"
      mkdir -p $out
    '';

  # preload 版: --extract で展開し、transitive 依存が正しく収集されていることを確認
  single-exe-preload-extract = pkgs.runCommand "check-single-exe-preload-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-single-exe-preload} --extract "$extractdir"

      # ラッパースクリプトの存在と実行
      test -x "$extractdir/bin/curl"
      output=$("$extractdir/bin/curl" --version)
      echo "$output"
      echo "$output" | grep -q "curl"

      # cleanup_env.so の存在確認
      test -f "$extractdir/lib/cleanup_env.so"

      # transitive な依存ライブラリの存在確認
      ls "$extractdir/lib/"
      test -n "$(find "$extractdir/lib" -name "libcurl.so*" -print -quit)"
      test -n "$(find "$extractdir/lib" -name "libz.so*" -o -name "libzstd.so*" -print -quit)"

      so_count=$(find "$extractdir/lib" -name "*.so*" | wc -l)
      echo "Found $so_count shared libraries"
      [ "$so_count" -ge 5 ]

      echo "PASS: single-exe-preload-extract"
      mkdir -p $out
    '';

  add-flag-rpath-run = pkgs.runCommand "check-add-flag-rpath-run"
    { }
    ''
      output=$(${test-add-flag-rpath} --)
      echo "$output"
      echo "$output" | grep -q "BUNDLED_CONTENT_OK"
      echo "PASS: add-flag-rpath-run"
      mkdir -p $out
    '';

  add-flag-rpath-extract = pkgs.runCommand "check-add-flag-rpath-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-add-flag-rpath} --extract "$extractdir"
      test -f "$extractdir/test/foo"
      output=$("$extractdir/bin/cat")
      echo "$output"
      echo "$output" | grep -q "BUNDLED_CONTENT_OK"
      echo "PASS: add-flag-rpath-extract"
      mkdir -p $out
    '';

  add-flag-preload-run = pkgs.runCommand "check-add-flag-preload-run"
    { }
    ''
      output=$(${test-add-flag-preload} --)
      echo "$output"
      echo "$output" | grep -q "BUNDLED_CONTENT_OK"
      echo "PASS: add-flag-preload-run"
      mkdir -p $out
    '';

  add-flag-preload-extract = pkgs.runCommand "check-add-flag-preload-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-add-flag-preload} --extract "$extractdir"
      test -f "$extractdir/test/foo"
      output=$("$extractdir/bin/cat")
      echo "$output"
      echo "$output" | grep -q "BUNDLED_CONTENT_OK"
      echo "PASS: add-flag-preload-extract"
      mkdir -p $out
    '';

  add-flag-preload-extract-space = pkgs.runCommand "check-add-flag-preload-extract-space"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-add-flag-preload-space} --extract "$extractdir"
      output=$("$extractdir/bin/expr")
      echo "$output"
      test "$output" = "7"
      echo "PASS: add-flag-preload-extract-space"
      mkdir -p $out
    '';

  # --env / --env-prefix / --env-suffix (rpath): exec mode
  env-rpath-run = pkgs.runCommand "check-env-rpath-run"
    { }
    ''
      # --env: simple set
      output=$(${test-env-rpath} -- NIX_BUNDLE_TEST_SET)
      echo "set: $output"
      test "$output" = "hello_world"

      # --env-prefix: var was empty
      output=$(${test-env-rpath} -- NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-empty: $output"
      test "$output" = "/new/prefix"

      # --env-prefix: var was already set
      output=$(NIX_BUNDLE_TEST_PREFIX=/existing ${test-env-rpath} -- NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-existing: $output"
      test "$output" = "/new/prefix:/existing"

      # --env-suffix: var was empty
      output=$(${test-env-rpath} -- NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-empty: $output"
      test "$output" = "/new/suffix"

      # --env-suffix: var was already set
      output=$(NIX_BUNDLE_TEST_SUFFIX=/existing ${test-env-rpath} -- NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-existing: $output"
      test "$output" = "/existing:/new/suffix"

      echo "PASS: env-rpath-run"
      mkdir -p $out
    '';

  # --env / --env-prefix / --env-suffix (rpath): extract mode
  env-rpath-extract = pkgs.runCommand "check-env-rpath-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-env-rpath} --extract "$extractdir"

      output=$("$extractdir/bin/printenv" NIX_BUNDLE_TEST_SET)
      echo "set: $output"
      test "$output" = "hello_world"

      output=$("$extractdir/bin/printenv" NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-empty: $output"
      test "$output" = "/new/prefix"

      output=$(NIX_BUNDLE_TEST_PREFIX=/existing "$extractdir/bin/printenv" NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-existing: $output"
      test "$output" = "/new/prefix:/existing"

      output=$("$extractdir/bin/printenv" NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-empty: $output"
      test "$output" = "/new/suffix"

      output=$(NIX_BUNDLE_TEST_SUFFIX=/existing "$extractdir/bin/printenv" NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-existing: $output"
      test "$output" = "/existing:/new/suffix"

      echo "PASS: env-rpath-extract"
      mkdir -p $out
    '';

  # --env / --env-prefix / --env-suffix (preload): exec mode
  env-preload-run = pkgs.runCommand "check-env-preload-run"
    { }
    ''
      # --env: simple set
      output=$(${test-env-preload} -- NIX_BUNDLE_TEST_SET)
      echo "set: $output"
      test "$output" = "hello_world"

      # --env-prefix: var was empty
      output=$(${test-env-preload} -- NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-empty: $output"
      test "$output" = "/new/prefix"

      # --env-prefix: var was already set
      output=$(NIX_BUNDLE_TEST_PREFIX=/existing ${test-env-preload} -- NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-existing: $output"
      test "$output" = "/new/prefix:/existing"

      # --env-suffix: var was empty
      output=$(${test-env-preload} -- NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-empty: $output"
      test "$output" = "/new/suffix"

      # --env-suffix: var was already set
      output=$(NIX_BUNDLE_TEST_SUFFIX=/existing ${test-env-preload} -- NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-existing: $output"
      test "$output" = "/existing:/new/suffix"

      echo "PASS: env-preload-run"
      mkdir -p $out
    '';

  # --env / --env-prefix / --env-suffix (preload): extract mode
  env-preload-extract = pkgs.runCommand "check-env-preload-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-env-preload} --extract "$extractdir"

      output=$("$extractdir/bin/printenv" NIX_BUNDLE_TEST_SET)
      echo "set: $output"
      test "$output" = "hello_world"

      output=$("$extractdir/bin/printenv" NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-empty: $output"
      test "$output" = "/new/prefix"

      output=$(NIX_BUNDLE_TEST_PREFIX=/existing "$extractdir/bin/printenv" NIX_BUNDLE_TEST_PREFIX)
      echo "prefix-existing: $output"
      test "$output" = "/new/prefix:/existing"

      output=$("$extractdir/bin/printenv" NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-empty: $output"
      test "$output" = "/new/suffix"

      output=$(NIX_BUNDLE_TEST_SUFFIX=/existing "$extractdir/bin/printenv" NIX_BUNDLE_TEST_SUFFIX)
      echo "suffix-existing: $output"
      test "$output" = "/existing:/new/suffix"

      echo "PASS: env-preload-extract"
      mkdir -p $out
    '';

  # Lambda zip の構造と transitive 依存を確認
  lambda-zip-structure = pkgs.runCommand "check-lambda-zip-structure"
    {
      nativeBuildInputs = [ pkgs.unzip pkgs.coreutils pkgs.findutils pkgs.gnugrep ];
    }
    ''
      workdir="$TMPDIR/lambda-check"
      mkdir -p "$workdir"
      unzip -q ${test-lambda-zip} -d "$workdir"

      # bootstrap の存在と実行権限
      test -f "$workdir/bootstrap"
      test -x "$workdir/bootstrap"

      # lib/ の存在と transitive 依存
      test -d "$workdir/lib"
      ls "$workdir/lib/"
      test -n "$(find "$workdir/lib" -name 'libcurl.so*' -print -quit)"
      test -n "$(find "$workdir/lib" -name 'libz.so*' -o -name 'libzstd.so*' -print -quit)"

      so_count=$(find "$workdir/lib" -name '*.so*' | wc -l)
      echo "Found $so_count shared libraries"
      [ "$so_count" -ge 5 ]

      echo "PASS: lambda-zip-structure ($so_count shared libs)"
      mkdir -p $out
    '';
  # Verify bun + resolve-tool.ts works in the Nix sandbox
  bun-resolve-tool = pkgs.runCommand "check-bun-resolve-tool"
    { nativeBuildInputs = [ pkgs.bun pkgs.patchelf ]; }
    ''
      result=$(bun run ${./..}/src/lib/resolve-tool.ts patchelf patchelf)
      echo "resolved: $result"
      test -x "$result"
      echo "PASS: bun-resolve-tool"
      mkdir -p $out
    '';
  # Verify gather-nix-deps.ts collects transitive deps from a Nix binary
  bun-gather-nix-deps = pkgs.runCommand "check-bun-gather-nix-deps"
    { nativeBuildInputs = [ pkgs.bun pkgs.patchelf ]; }
    ''
      output=$(bun run ${./..}/src/lib/gather-nix-deps.ts ${pkgs.curl}/bin/curl)
      echo "$output"

      # Should find libcurl and several transitive deps
      echo "$output" | grep -q "libcurl"
      count=$(echo "$output" | wc -l)
      echo "Found $count libraries"
      [ "$count" -ge 5 ]

      echo "PASS: bun-gather-nix-deps"
      mkdir -p $out
    '';
  # Verify patchelf.ts reads interpreter, needed, and rpath from a real binary
  bun-patchelf = pkgs.runCommand "check-bun-patchelf"
    { nativeBuildInputs = [ pkgs.bun pkgs.patchelf ]; }
    ''
      output=$(bun run ${./..}/src/lib/patchelf.ts ${pkgs.curl}/bin/curl)
      echo "$output"

      # interpreter should be an absolute /nix/store path
      echo "$output" | grep -q "^interpreter: /nix/store/"

      # needed should include libcurl
      echo "$output" | grep -q "libcurl"

      echo "PASS: bun-patchelf"
      mkdir -p $out
    '';

  # script bundle: single binary, execute mode
  script-bundle-single-run = pkgs.runCommand "check-script-bundle-single-run"
    { }
    ''
      output=$(${test-bundle-script-single} --)
      echo "$output"
      echo "$output" | grep -q "SCRIPT_START"
      echo "$output" | grep -q "SCRIPT_END"
      echo "$output" | grep -q "coreutils"
      echo "PASS: script-bundle-single-run"
      mkdir -p $out
    '';

  # script bundle: single binary, extract mode
  script-bundle-single-extract = pkgs.runCommand "check-script-bundle-single-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-bundle-script-single} --extract "$extractdir"

      # Verify structure
      test -f "$extractdir/entry.sh"
      test -f "$extractdir/orig/cat"
      test -d "$extractdir/lib-cat"
      test -x "$extractdir/bin/cat"
      test -x "$extractdir/bin/test-script-single"

      # Run via wrapper
      output=$("$extractdir/bin/test-script-single")
      echo "$output"
      echo "$output" | grep -q "SCRIPT_START"
      echo "$output" | grep -q "coreutils"

      echo "PASS: script-bundle-single-extract"
      mkdir -p $out
    '';

  # script bundle: multi binary, execute mode
  script-bundle-multi-run = pkgs.runCommand "check-script-bundle-multi-run"
    { }
    ''
      output=$(${test-bundle-script-multi} --)
      echo "$output"
      echo "$output" | grep -q "MULTI_START"
      echo "$output" | grep -q "MULTI_END"
      echo "$output" | grep -q "curl"
      echo "$output" | grep -q "coreutils"
      echo "PASS: script-bundle-multi-run"
      mkdir -p $out
    '';

  # script bundle: multi binary, extract mode with RPATH check
  script-bundle-multi-extract = pkgs.runCommand "check-script-bundle-multi-extract"
    { nativeBuildInputs = [ pkgs.patchelf ]; }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-bundle-script-multi} --extract "$extractdir"

      # Verify structure
      test -f "$extractdir/entry.sh"
      test -f "$extractdir/orig/curl"
      test -f "$extractdir/orig/cat"
      test -d "$extractdir/lib-curl"
      test -d "$extractdir/lib-cat"
      test -x "$extractdir/bin/curl"
      test -x "$extractdir/bin/cat"
      test -x "$extractdir/bin/test-script-multi"

      # Verify per-binary RPATH
      rpath=$(patchelf --print-rpath "$extractdir/orig/curl")
      echo "curl RPATH: $rpath"
      echo "$rpath" | grep -q "\$ORIGIN/../lib-curl"

      rpath=$(patchelf --print-rpath "$extractdir/orig/cat")
      echo "cat RPATH: $rpath"
      echo "$rpath" | grep -q "\$ORIGIN/../lib-cat"

      # Run via wrapper
      output=$("$extractdir/bin/test-script-multi")
      echo "$output"
      echo "$output" | grep -q "MULTI_START"
      echo "$output" | grep -q "curl"
      echo "$output" | grep -q "coreutils"

      echo "PASS: script-bundle-multi-extract"
      mkdir -p $out
    '';

  # script bundle: multi binary preload, execute mode
  script-bundle-multi-preload-run = pkgs.runCommand "check-script-bundle-multi-preload-run"
    { }
    ''
      output=$(${test-bundle-script-multi-preload} --)
      echo "$output"
      echo "$output" | grep -q "MULTI_START"
      echo "$output" | grep -q "MULTI_END"
      echo "$output" | grep -q "curl"
      echo "$output" | grep -q "coreutils"
      echo "PASS: script-bundle-multi-preload-run"
      mkdir -p $out
    '';

  # script bundle: multi binary preload, extract mode
  script-bundle-multi-preload-extract = pkgs.runCommand "check-script-bundle-multi-preload-extract"
    { }
    ''
      extractdir="$TMPDIR/extracted"
      ${test-bundle-script-multi-preload} --extract "$extractdir"

      # Verify structure
      test -f "$extractdir/entry.sh"
      test -f "$extractdir/orig/curl"
      test -f "$extractdir/orig/cat"
      test -d "$extractdir/lib-curl"
      test -d "$extractdir/lib-cat"
      test -f "$extractdir/lib-curl/cleanup_env.so"
      test -f "$extractdir/lib-cat/cleanup_env.so"
      test -x "$extractdir/bin/curl"
      test -x "$extractdir/bin/cat"
      test -x "$extractdir/bin/test-script-multi-preload"

      # Run via wrapper
      output=$("$extractdir/bin/test-script-multi-preload")
      echo "$output"
      echo "$output" | grep -q "MULTI_START"
      echo "$output" | grep -q "curl"
      echo "$output" | grep -q "coreutils"

      echo "PASS: script-bundle-multi-preload-extract"
      mkdir -p $out
    '';
}
