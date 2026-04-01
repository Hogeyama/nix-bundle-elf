{
  description = "A small library to build a stand-alone executable using patchelf";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils/main";
  };
  outputs = { self, nixpkgs, flake-utils, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      single-exe =
        # * usage:
        #     single-exe {
        #       inherit pkgs;
        #       name = "foo";
        #       target = "${pkgs.foo}/bin/foo";
        #       type = "preload";  # optional, default "rpath"
        #     }
        # * usage of the generated file:
        #   * `result --extract /path/to/dir` extracts the target
        #     and it's dependencies to `/path/to/dir`. It also creates a wrapper
        #     scripts `/path/to/dir/bin/$name` that runs the target.
        #   * `result [--] ARGS` extract the bundle to temporary directory
        #     and runs the target with `ARGS`.
        #
        # type:
        #   "rpath"   — uses patchelf --set-rpath (default, simpler)
        #   "preload" — uses LD_PRELOAD (preserves NOTE segments, Node.js SEA safe)
        { name
        , target
        , pkgs
        , type ? "rpath"
        , extraFiles ? { }
        , addFlags ? [ ]
        }:
        let
          addFlagArgs =
            pkgs.lib.concatMapStrings (flag: " --add-flag ${pkgs.lib.escapeShellArg flag}") addFlags;
          includeArgs =
            pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList
              (dest: src: " --include ${pkgs.lib.escapeShellArg "${toString src}:${dest}"}")
              extraFiles);
        in
        assert builtins.elem type [ "rpath" "preload" ];
        if type == "rpath" then
          pkgs.runCommandCC name { buildInputs = [ pkgs.bun pkgs.patchelf pkgs.gnutar ]; }
            ''
              bun run ${./.}/src/cli.ts rpath --no-nix-locate --format exe -o $out${includeArgs}${addFlagArgs} ${target}
            ''
        else
          pkgs.runCommandCC name { buildInputs = [ pkgs.bun pkgs.patchelf pkgs.gnutar ]; }
            ''
              bun run ${./.}/src/cli.ts preload --no-nix-locate -o $out${includeArgs}${addFlagArgs} ${target}
            '';

      aws-lambda-zip =
        { name
        , target
        , pkgs
        }:
        pkgs.runCommandCC name { buildInputs = [ pkgs.bun pkgs.patchelf pkgs.zip ]; }
          ''
            bun run ${./.}/src/cli.ts rpath --no-nix-locate --format lambda -o function.zip ${target}
            mv function.zip $out
          '';
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        test-single-exe = self.lib.${system}.single-exe {
          inherit pkgs;
          name = "curl";
          target = "${pkgs.curl}/bin/curl";
        };
        test-single-exe-preload = self.lib.${system}.single-exe {
          inherit pkgs;
          name = "curl";
          target = "${pkgs.curl}/bin/curl";
          type = "preload";
        };
        test-lambda-zip = self.lib.${system}.aws-lambda-zip {
          inherit pkgs;
          name = "curl";
          target = "${pkgs.curl}/bin/curl";
        };
        test-include-file = pkgs.writeText "test-include" "BUNDLED_CONTENT_OK";
        test-add-flag-rpath = self.lib.${system}.single-exe {
          inherit pkgs;
          name = "cat";
          target = "${pkgs.coreutils}/bin/cat";
          extraFiles = { "test/foo" = test-include-file; };
          addFlags = [ "%ROOT/test/foo" ];
        };
        test-add-flag-preload = self.lib.${system}.single-exe {
          inherit pkgs;
          name = "cat";
          target = "${pkgs.coreutils}/bin/cat";
          type = "preload";
          extraFiles = { "test/foo" = test-include-file; };
          addFlags = [ "%ROOT/test/foo" ];
        };
        test-add-flag-preload-space = self.lib.${system}.single-exe {
          inherit pkgs;
          name = "python3";
          target = "${pkgs.python3}/bin/python3";
          type = "preload";
          addFlags = [
            "-c"
            "import sys; print(repr(sys.argv[0]))"
            "foo bar"
          ];
        };
        # FHS 環境: sandbox 内で自己展開ラッパーを実行するために使う
        testFHSRun = pkgs.buildFHSEnv {
          name = "test-fhs-run";
          targetPkgs = p: [ p.bash p.coreutils p.gnutar p.gnugrep p.findutils p.patchelf ];
          runScript = "bash";
        };
      in
      {
        packages = {
          example-single-exe = self.lib.${system}.single-exe {
            inherit pkgs;
            name = "example";
            target = "${pkgs.curl}/bin/curl";
          };
          example-lambda-zip = self.lib.${system}.aws-lambda-zip {
            inherit pkgs;
            name = "example";
            target = "${pkgs.hello}/bin/hello";
          };
        };
        checks = {
          # curl --version で transitive な依存を含むバンドルが動作することを確認
          single-exe-run = pkgs.runCommand "check-single-exe-run"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                output=$(${test-single-exe} -- --version)
                echo "$output"
                echo "$output" | grep -q "curl"
                echo "$output" | grep -q "libcurl"
                echo "PASS: single-exe-run"
              '
              mkdir -p $out
            '';

          # --extract で展開し、transitive 依存が正しく収集されていることを確認
          single-exe-extract = pkgs.runCommand "check-single-exe-extract"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
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
              '
              mkdir -p $out
            '';

          # 展開後のバイナリ・ライブラリの RPATH が正しく設定されていることを確認
          single-exe-extract-rpath = pkgs.runCommand "check-single-exe-extract-rpath"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
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
              '
              mkdir -p $out
            '';

          # preload 版: curl --version で動作確認
          single-exe-preload-run = pkgs.runCommand "check-single-exe-preload-run"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                output=$(${test-single-exe-preload} -- --version)
                echo "$output"
                echo "$output" | grep -q "curl"
                echo "$output" | grep -q "libcurl"
                echo "PASS: single-exe-preload-run"
              '
              mkdir -p $out
            '';

          # preload 版: --extract で展開し、transitive 依存が正しく収集されていることを確認
          single-exe-preload-extract = pkgs.runCommand "check-single-exe-preload-extract"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
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
              '
              mkdir -p $out
            '';

          add-flag-rpath-run = pkgs.runCommand "check-add-flag-rpath-run"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                output=$(${test-add-flag-rpath} --)
                echo "$output"
                echo "$output" | grep -q "BUNDLED_CONTENT_OK"
                echo "PASS: add-flag-rpath-run"
              '
              mkdir -p $out
            '';

          add-flag-rpath-extract = pkgs.runCommand "check-add-flag-rpath-extract"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                extractdir="$TMPDIR/extracted"
                ${test-add-flag-rpath} --extract "$extractdir"
                test -f "$extractdir/test/foo"
                output=$("$extractdir/bin/cat")
                echo "$output"
                echo "$output" | grep -q "BUNDLED_CONTENT_OK"
                echo "PASS: add-flag-rpath-extract"
              '
              mkdir -p $out
            '';

          add-flag-preload-run = pkgs.runCommand "check-add-flag-preload-run"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                output=$(${test-add-flag-preload} --)
                echo "$output"
                echo "$output" | grep -q "BUNDLED_CONTENT_OK"
                echo "PASS: add-flag-preload-run"
              '
              mkdir -p $out
            '';

          add-flag-preload-extract = pkgs.runCommand "check-add-flag-preload-extract"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                extractdir="$TMPDIR/extracted"
                ${test-add-flag-preload} --extract "$extractdir"
                test -f "$extractdir/test/foo"
                output=$("$extractdir/bin/cat")
                echo "$output"
                echo "$output" | grep -q "BUNDLED_CONTENT_OK"
                echo "PASS: add-flag-preload-extract"
              '
              mkdir -p $out
            '';

          add-flag-preload-extract-space = pkgs.runCommand "check-add-flag-preload-extract-space"
            { }
            ''
              ${testFHSRun}/bin/test-fhs-run -c '
                extractdir="$TMPDIR/extracted"
                ${test-add-flag-preload-space} --extract "$extractdir"
                output=$("$extractdir/bin/python3")
                expected=$(printf "\\047foo bar\\047")
                echo "$output"
                test "$output" = "$expected"
                echo "PASS: add-flag-preload-extract-space"
              '
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
              result=$(bun run ${./.}/src/lib/resolve-tool.ts patchelf patchelf)
              echo "resolved: $result"
              test -x "$result"
              echo "PASS: bun-resolve-tool"
              mkdir -p $out
            '';
          # Verify gather-nix-deps.ts collects transitive deps from a Nix binary
          bun-gather-nix-deps = pkgs.runCommand "check-bun-gather-nix-deps"
            { nativeBuildInputs = [ pkgs.bun pkgs.patchelf ]; }
            ''
              output=$(bun run ${./.}/src/lib/gather-nix-deps.ts ${pkgs.curl}/bin/curl)
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
              output=$(bun run ${./.}/src/lib/patchelf.ts ${pkgs.curl}/bin/curl)
              echo "$output"

              # interpreter should be an absolute /nix/store path
              echo "$output" | grep -q "^interpreter: /nix/store/"

              # needed should include libcurl
              echo "$output" | grep -q "libcurl"

              echo "PASS: bun-patchelf"
              mkdir -p $out
            '';
        };
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.patchelf
            pkgs.bun
            pkgs.just
            pkgs.gcc
            pkgs.gnutar
            pkgs.gnugrep
            pkgs.coreutils
            pkgs.typescript
            pkgs.biome
          ];
        };
        lib = {
          inherit single-exe aws-lambda-zip;
        };
      }
    );
}
