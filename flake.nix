{
  description = "yarnpnp2nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?rev=95ea544c84ebed84a31896b0ecea2570e5e0e236";
    nixpkgs-latest.url = "github:nixos/nixpkgs?rev=c80f6a7e10b39afcc1894e02ef785b1ad0b0d7e5";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs-latest";
    utils.url = "github:numtide/flake-utils?rev=6ee9ebb6b1ee695d2cacc4faa053a7b9baa76817";
    hercules-ci-effects.url = "github:hercules-ci/hercules-ci-effects";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-latest,
      utils,
      treefmt-nix,
      hercules-ci-effects,
      self,
      ...
    }:
    let
      overlay = final: prev: {
        yarnBerry = final.callPackage ./yarn.nix { };
        yarn-plugin-yarnpnp2nix = final.callPackage ./yarnPlugin.nix { };
        yarnpnp2nixLib = import ./lib/mkYarnPackage.nix {
          defaultPkgs = final;
          lib = final.lib;
        };
      };
    in
    (utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
        effectLib = hercules-ci-effects.lib.withPkgs pkgs;
        pkgs-latest = import nixpkgs-latest {
          inherit system;
        };
        inherit (pkgs) lib;
        treefmt-eval = (import treefmt-nix).evalModule pkgs {
          programs.nixfmt.enable = true;
          # programs.nixfmt.srict = true;
          programs.dprint.enable = true;
          programs.dprint = {
            includes = lib.mkForce [
              "**/*.ts"
            ];
          };
          programs.dprint.settings = {
            plugins = [
              "https://plugins.dprint.dev/typescript-0.94.0.wasm"
            ];
            indentWidth = 2;
            lineWidth = 100;
            incremental = true;
            useTabs = false;
            typescript = {
              "arrowFunction.useParentheses" = "preferNone";
              "binaryExpression.linePerExpression" = true;
              "enumDeclaration.memberSpacing" = "newLine";
              "jsx.quoteStyle" = "preferSingle";
              lineWidth = 80;
              "memberExpression.linePerExpression" = true;
              nextControlFlowPosition = "sameLine";
              quoteProps = "asNeeded";
              quoteStyle = "preferSingle";
              semiColons = "asi";
            };
          };
          settings.formatter = {
            nixfmt = {
              excludes = [
                "**/yarn-manifest.nix"
              ];
              includes = lib.mkForce [
                "*.nix"
              ];
            };
            dprint = {
              includes = lib.mkForce [
                "*.ts"
              ];
            };
          };
          settings.global = {
            on-unmatched = "info";
            excludes = [
              "**/.git*"
              "**/.pnp.*"
              "*.js"
              "*.json"
              "*.md"
              "*.sh"
              "*.txt"
              "*.yml"
              "*/.yarn/*"
              ".envrc"
              "LICENSE"
              "package.json"
              "test/workspace/*"
              "yarn-manifest.nix"
            ];
          };
        };
        treefmt-package = treefmt-eval.config.build.wrapper;
      in
      {
        packages = rec {
          treefmt = treefmt-package;
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
            patch =
              let
                workspace = pkgs.yarnpnp2nixLib.mkYarnPackagesFromManifest {
                  yarnManifest = import ./tests/patch/yarn-manifest.nix;
                };
              in
              pkgs.runCommand "test-patch" { } ''
                result=$(${workspace."three@workspace:packages/three"}/bin/three)
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
        treefmt-config = treefmt-eval.config;
        devShells = {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs
              yarnBerry
              pkgs-latest.nixfmt-rfc-style
              treefmt-package
              hci
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
        effects = {
          runTests = effectLib.mkEffect {
            effectScript = lib.getExe self.packages.${system}.yarnpnp2nix-test;
          };
        };
      }
    ))
    // {
      overlays.default = overlay;
      herculesCI.ciSystems = [ "x86_64-linux" ];
    };
}
