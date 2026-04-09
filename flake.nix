{
  description = "A small library to build a stand-alone executable using patchelf";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils/main";
  };
  outputs = { nixpkgs, flake-utils, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        nix-bundle-elf = pkgs.stdenv.mkDerivation {
          pname = "nix-bundle-elf";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.bun pkgs.makeWrapper ];
          dontStrip = true;
          buildPhase = ''
            runHook preBuild
            export HOME=$(mktemp -d)
            bun build --compile src/cli.ts --outfile nix-bundle-elf
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp nix-bundle-elf $out/bin/nix-bundle-elf
            wrapProgram $out/bin/nix-bundle-elf \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.patchelf pkgs.gnutar pkgs.gcc ]}
            runHook postInstall
          '';
        };

        # * usage:
        #     single-exe {
        #       name = "foo";
        #       target = "${pkgs.foo}/bin/foo";
        #       type = "preload";  # optional, default "rpath"
        #       extraLibs = [ "${pkgs.bar}/lib/libbar.so" ];  # optional
        #       resolveWith = [ "${pkgs.foo}/lib/libfoo.so" ];  # optional
        #     }
        # * usage of the generated file:
        #   * `result --extract /path/to/dir` extracts the target
        #     and it's dependencies to `/path/to/dir`. It also creates a wrapper
        #     script `/path/to/dir/bin/$name` that runs the target.
        #   * `result [--] ARGS` extract the bundle to temporary directory
        #     and runs the target with `ARGS`.
        #
        # type:
        #   "rpath"   — uses patchelf --set-rpath (default, simpler)
        #   "preload" — uses LD_PRELOAD (preserves NOTE segments, Node.js SEA safe)
        single-exe =
          args@{ name
          , target
          , type ? "rpath"
          , extraFiles ? { }
          , extraLibs ? [ ]
          , resolveWith ? [ ]
          , addFlags ? [ ]
          , env ? [ ]
          , ...
          }:
          let
            addFlagArgs =
              pkgs.lib.concatMapStrings (flag: " --add-flag ${pkgs.lib.escapeShellArg flag}") addFlags;
            extraLibArgs =
              pkgs.lib.concatMapStrings (lib: " --extra-lib ${pkgs.lib.escapeShellArg lib}") extraLibs;
            resolveWithArgs =
              pkgs.lib.concatMapStrings (p: " --resolve-with ${pkgs.lib.escapeShellArg (toString p)}") resolveWith;
            includeArgs =
              pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList
                (dest: src: " --include ${pkgs.lib.escapeShellArg "${toString src}:${dest}"}")
                extraFiles);
            envToArgs = e:
              if e.action == "replace" then
                " --env ${pkgs.lib.escapeShellArg e.key} ${pkgs.lib.escapeShellArg e.value}"
              else if e.action == "prepend" then
                " --env-prefix ${pkgs.lib.escapeShellArg e.key} ${pkgs.lib.escapeShellArg e.separator} ${pkgs.lib.escapeShellArg e.value}"
              else if e.action == "append" then
                " --env-suffix ${pkgs.lib.escapeShellArg e.key} ${pkgs.lib.escapeShellArg e.separator} ${pkgs.lib.escapeShellArg e.value}"
              else
                throw "env: unknown action '${e.action}' (expected replace, prepend, or append)";
            envArgs = pkgs.lib.concatMapStrings envToArgs env;
            drv =
              assert builtins.elem type [ "rpath" "preload" ];
              assert extraLibs == [ ] || type != "rpath"
                || throw "single-exe: extraLibs is not supported with rpath strategy (use type = \"preload\" instead)";
              if type == "rpath" then
                pkgs.runCommand name { nativeBuildInputs = [ nix-bundle-elf ]; }
                  ''
                    nix-bundle-elf rpath --no-nix-locate --format exe -o "$TMPDIR/${name}"${includeArgs}${resolveWithArgs}${addFlagArgs}${envArgs} ${target}
                    mv "$TMPDIR/${name}" $out
                  ''
              else
                pkgs.runCommand name { nativeBuildInputs = [ nix-bundle-elf ]; }
                  ''
                    nix-bundle-elf preload --no-nix-locate -o "$TMPDIR/${name}"${includeArgs}${resolveWithArgs}${extraLibArgs}${addFlagArgs}${envArgs} ${target}
                    mv "$TMPDIR/${name}" $out
                  '';
          in
          if args ? pkgs
          then builtins.trace "warning: single-exe: the `pkgs` argument is deprecated and has no effect" drv
          else drv;

        aws-lambda-zip =
          args@{ name
          , target
          , ...
          }:
          let
            drv = pkgs.runCommand name { nativeBuildInputs = [ nix-bundle-elf pkgs.zip ]; }
              ''
                nix-bundle-elf rpath --no-nix-locate --format lambda -o function.zip ${target}
                mv function.zip $out
              '';
          in
          if args ? pkgs
          then builtins.trace "warning: aws-lambda-zip: the `pkgs` argument is deprecated and has no effect" drv
          else drv;

        bundle-script =
          args@{ name
          , script
          , binaries
          , type ? "rpath"
          , extraFiles ? { }
          , extraLibs ? [ ]
          , env ? [ ]
          , ...
          }:
          let
            bundleBinArgs =
              pkgs.lib.concatMapStrings
                (b: " --bundle-bin ${pkgs.lib.escapeShellArg "${b.name}:${b.target}"}")
                binaries;
            includeArgs =
              pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList
                (dest: src: " --include ${pkgs.lib.escapeShellArg "${toString src}:${dest}"}")
                extraFiles);
            extraLibArgs =
              pkgs.lib.concatMapStrings (lib: " --extra-lib ${pkgs.lib.escapeShellArg lib}") extraLibs;
            envToArgs = e:
              if e.action == "replace" then
                " --env ${pkgs.lib.escapeShellArg e.key} ${pkgs.lib.escapeShellArg e.value}"
              else if e.action == "prepend" then
                " --env-prefix ${pkgs.lib.escapeShellArg e.key} ${pkgs.lib.escapeShellArg e.separator} ${pkgs.lib.escapeShellArg e.value}"
              else if e.action == "append" then
                " --env-suffix ${pkgs.lib.escapeShellArg e.key} ${pkgs.lib.escapeShellArg e.separator} ${pkgs.lib.escapeShellArg e.value}"
              else
                throw "env: unknown action '${e.action}' (expected replace, prepend, or append)";
            envArgs = pkgs.lib.concatMapStrings envToArgs env;
            drv =
              assert builtins.elem type [ "rpath" "preload" ];
              assert extraLibs == [ ] || type != "rpath"
                || throw "bundle-script: extraLibs is not supported with rpath strategy (use type = \"preload\" instead)";
              pkgs.runCommand name { nativeBuildInputs = [ nix-bundle-elf ]; }
                ''
                  nix-bundle-elf script --no-nix-locate --type ${type} -o "$TMPDIR/${name}"${bundleBinArgs}${includeArgs}${extraLibArgs}${envArgs} ${script}
                  mv "$TMPDIR/${name}" $out
                '';
          in
          if args ? pkgs
          then builtins.trace "warning: bundle-script: the `pkgs` argument is deprecated and has no effect" drv
          else drv;

      in
      {
        packages = {
          default = nix-bundle-elf;
          example-single-exe = single-exe {
            name = "example";
            target = "${pkgs.curl}/bin/curl";
          };
          example-lambda-zip = aws-lambda-zip {
            name = "example";
            target = "${pkgs.hello}/bin/hello";
          };
        };

        checks = import ./nix/tests.nix {
          inherit pkgs single-exe aws-lambda-zip bundle-script;
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
          ];
        };

        lib = {
          inherit single-exe aws-lambda-zip bundle-script;
        };
      }
    );
}
