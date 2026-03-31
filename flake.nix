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
        }:
          assert builtins.elem type [ "rpath" "preload" ];
          if type == "rpath" then
            pkgs.runCommandCC name { buildInputs = [ pkgs.patchelf pkgs.gnutar ]; }
              ''
                bundled=$(bash ${./.}/bundle-rpath.bash --no-nix-locate --format exe ${target} ${name})
                mv $bundled $out
              ''
          else
            pkgs.runCommandCC name { buildInputs = [ pkgs.patchelf pkgs.gnutar ]; }
              ''
                bash ${./.}/bundle-preload.bash --no-nix-locate -o ${name} ${target}
                mv ${name} $out
              '';

      aws-lambda-zip =
        { name
        , target
        , pkgs
        }:
        pkgs.runCommandCC name { buildInputs = [ pkgs.patchelf pkgs.zip ]; }
          ''
            bundled=$(bash ${./.}/bundle-rpath.bash --no-nix-locate --format lambda ${target} ${name})
            mv $bundled $out
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
        # FHS 環境: sandbox 内に /usr/bin/env が無いため、
        # バンドル済みスクリプト (#!/usr/bin/env bash) の実行に必要
        testFHSRun = pkgs.buildFHSUserEnv {
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
        };
        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.patchelf pkgs.just pkgs.gcc pkgs.gnutar pkgs.gnugrep pkgs.coreutils ];
        };
        lib = {
          inherit single-exe aws-lambda-zip;
        };
      }
    );
}
