{
  description = "yarnpnp2nix";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs?rev=566e53c2ad750c84f6d31f9ccb9d00f823165550;
    utils.url = github:numtide/flake-utils;
    flake-compat ={
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, utils, ... }:
    let
      overlay = final: prev: {
        yarnBerry = final.callPackage ./yarn.nix {};
        yarn-plugin-yarnpnp2nix = final.callPackage ./yarnPlugin.nix {};
        yarnpnp2nixLib = import ./lib/mkYarnPackage.nix { defaultPkgs = final; lib = final.lib; };
      };
    in (utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [overlay];
        };
        inherit (pkgs) lib;
      in
      {
        packages = rec {
          default = pkgs.yarn-plugin-yarnpnp2nix;
          yarn-plugin = pkgs.yarn-plugin-yarnpnp2nix;
          yarnBerry = pkgs.yarnBerry;
          yarnpnp2nix-test = pkgs.writeShellApplication {
            name = "yarnpnp2nix-test";
            runtimeInputs = [ pkgs.jq ];
            text = builtins.readFile ./runTests.sh;
          };
          yarnpnp2nix-plugin-upgrade-deps = pkgs.writeShellApplication {
            name = "yarnpnp2nix-plugin-upgrade-deps";
            runtimeInputs = [ yarnBerry ];
            text = ''
              cd plugin
              yarn up -E @yarnpkg/cli @yarnpkg/core @yarnpkg/fslib @yarnpkg/libzip @yarnpkg/plugin-file @yarnpkg/plugin-pnp @yarnpkg/pnp @yarnpkg/builder
            '';
          };
          tests = {
            patch = let
              workspace = pkgs.yarnpnp2nixLib.mkYarnPackagesFromManifest {
                yarnManifest = import ./tests/patch/yarn-manifest.nix;
              };
            in
            pkgs.runCommand "test-patch" {} ''
              result=$(${lib.getExe workspace."three@workspace:packages/three"})
              echo result: $result

              if [[ $result == true ]]; then
                echo ok > $out
              else
                echo "expected true, got: $result"
                exit 1
              fi
            '';
          };
        };
        devShells = {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs
              yarnBerry
            ];
          };
          tests-patch = pkgs.mkShell {
            packages = with pkgs; [
              nodejs
              yarnBerry
            ];
            shellHook = ''
              export YARN_PLUGINS=${pkgs.yarn-plugin-yarnpnp2nix};
            '';
          };
        };
        lib = pkgs.yarnpnp2nixLib;
      }
    ))
    //
    { overlays.default = overlay; }
  ;
}
