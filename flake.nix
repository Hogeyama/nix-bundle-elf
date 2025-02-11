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
            bundled=$(bash ${./bundle.bash} --format exe ${target} ${name})
            mv $bundled $out
          '';

      aws-lambda-zip =
        { name
        , target
        , pkgs
        }:
        pkgs.runCommandCC name { buildInputs = [ pkgs.patchelf pkgs.zip ]; }
          ''
            bundled=$(bash ${./bundle.bash} --format lambda ${target} ${name})
            mv $bundled $out
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
