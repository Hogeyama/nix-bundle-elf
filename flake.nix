{
  description = "A small library to build a stand-alone executable using patchelf";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils/main";
  };
  outputs = { self, nixpkgs, flake-utils, ... }:
    let
      supportedSystems = [ "x86_64-linux" ];

      single-exe =
        # * usage:
        #     single-exe {
        #       inherit pkgs;
        #       name = "foo";
        #       target = "${pkgs.foo}/bin/foo";
        #     }
        # * usage of the generated file:
        #   * `result --extract /path/to/dir` extracts the target
        #     and it's dependencies to `/path/to/dir`. It also creates a wrapper
        #     scripts `/path/to/dir/bin/$name` that runs the target.
        #   * `result [--] ARGS` extract the bundle to temporary directory
        #     and runs the target with `ARGS`.
        { name
        , target
        , pkgs
        }:
        pkgs.runCommandCC name { buildInputs = [ pkgs.patchelf pkgs.zip ]; }
          ''
            tmp=$(mktemp -d)
            mkdir -p $tmp
            pushd $tmp
            mkdir orig lib

            # copy target
            cp ${target} orig/${name}

            # get interpreter
            interpreter=$(patchelf --print-interpreter orig/${name})
            interpreter_basename=$(basename $interpreter)

            # copy & patchelf dynamic libraries
            pushd lib
            mapfile -t LIBS < <(ldd ../orig/${name} | grep -F '=> /' | awk '{print $3}')
            for lib in "''${LIBS[@]}"; do
              lib_basename=$(basename "$lib")
              if [[ "$lib_basename" = "$interpreter_basename" ]]; then
                continue
              fi
              cp "$lib" .
              chmod +w $lib_basename
              patchelf --set-rpath '$ORIGIN' --force-rpath $lib_basename
              chmod -w $lib_basename
            done
            cp "$interpreter" .
            popd #lib

            # patchelf executable
            chmod +w orig/${name}
            patchelf --set-rpath '$ORIGIN/../lib' --force-rpath orig/${name}
            chmod -w orig/${name}

            # zip
            zip -qr bundle.zip .

            # create single script that self-extracts and runs
            # TODO is this posix-compliant?
            bundled=${name}-bundled
            touch $bundled
            chmod +x $bundled
            cat - bundle.zip > $bundled <<EOF
            #!/usr/bin/env bash
            set -eu
            TEMP="\$(mktemp -d \''${TMPDIR:-/tmp}/${name}.XXXXXX)"
            trap 'rm -rf \$TEMP' EXIT
            N=\$(grep -an "^#START_OF_ZIP#" "\$0" | cut -d: -f1)
            tail -n +"\$((N + 1))" <"\$0" > "\$TEMP/self.zip"
            if [[ "\''${1:-}" == "--extract" ]]; then
              if [[ -z "\''${2:-}" ]]; then
                echo "Usage: \$0 --extract <path>"
                exit 1
              fi
              if [[ -e "\$2" ]]; then
                echo "Error: \$2 already exists"
                exit 1
              fi
              TARGET=\$(realpath "\$2")
              unzip -qd "\$TARGET" "\$TEMP/self.zip"
              mkdir -p "\$TARGET/bin"
              cat - >"\$TARGET/bin/${name}" <<EOF2
            #!/usr/bin/env bash
            exec "\$TARGET/lib/$interpreter_basename" --argv0 "\\\$0" "\$TARGET/orig/${name}" "\\\$@"
            EOF2
              chmod +x "\$TARGET/bin/${name}"
              echo "successfully extracted to \$2"
            else
              if [[ "\''${1:-}" == "--" ]]; then
                shift
              fi
              unzip -qqd "\$TEMP" "\$TEMP/self.zip" >/dev/null
              "\$TEMP/lib/$interpreter_basename" --argv0 "\$0" "\$TEMP/orig/${name}" "\$@"
            fi
            exit 0
            #START_OF_ZIP#
            EOF

            mv $bundled $out
          '';
      aws-lambda-zip =
        { name
        , target
        , pkgs
        }:
        pkgs.runCommandCC name { buildInputs = [ pkgs.patchelf pkgs.zip ]; }
          ''
            mkdir $out $out/lib
            pushd $out

            cp ${target} bootstrap

            # get interpreter
            interpreter=$(basename "$(patchelf --print-interpreter bootstrap)")

            # copy & patchelf dynamic libraries
            pushd lib
            mapfile -t LIBS < <(ldd ../bootstrap | grep -F '=> /' | awk '{print $3}')
            for lib in "''${LIBS[@]}"; do
              cp "$lib" .
              lib=$(basename "$lib")
              if [[ "$lib" = "$interpreter" ]]; then
                continue
              fi
              chmod +w $lib
              patchelf --set-rpath '$ORIGIN' --force-rpath $lib
              chmod -w $lib
            done
            popd #lib

            # patchelf executable
            chmod +w bootstrap
            patchelf \
              --set-interpreter ./lib/$interpreter \
              --set-rpath ./lib \
              --force-rpath \
              bootstrap
            chmod -w bootstrap

            # zip
            zip -qr function.zip .

            rm -r lib bootstrap
          '';
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = {
          example-single-exe = self.lib.${system}.single-exe {
            inherit pkgs;
            name = "example";
            target = "${pkgs.hello}/bin/hello";
          };
          example-lambda-zip = self.lib.${system}.aws-lambda-zip {
            inherit pkgs;
            name = "example";
            target = "${pkgs.hello}/bin/hello";
          };
        };
        lib = {
          inherit single-exe aws-lambda-zip;
        };
      }
    );
}
