{
  description = "yarnpnp2nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?rev=567a49d1913ce81ac6e9582e3553dd90a955875f";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    utils.url = "github:numtide/flake-utils";
    hercules-ci-effects.url = "github:hercules-ci/hercules-ci-effects";
    flake-compat = {
      url = "github:nixos/flake-compat";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      utils,
      treefmt-nix,
      hercules-ci-effects,
      self,
      ...
    }:
    let
      overlay = final: prev: {
        nodejs = final.nodejs_26;
        yarnBerry = final.callPackage ./yarn.nix { };
        yarn-plugin-yarnpnp2nix = final.callPackage ./yarnPlugin.nix { };
        yarn-plugin-yarnpnp2nix-dynamic = final.callPackage ./yarnPlugin.nix {
          yarnpnp2nixBuildBynamically = true;
        };
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
        formatter = treefmt-package;
        packages = rec {
          treefmt = treefmt-package;
          default = pkgs.yarn-plugin-yarnpnp2nix-dynamic;
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
          rebuild-plugin = pkgs.writeShellApplication {
            name = "rebuild-plugin";
            text =
              let
                git = lib.getExe pkgs.git;
              in
              ''
                result=$(nix build --no-link --print-out-paths)
                echo "built plugin: $result"
                cp "$result" plugin.js
                if ! git diff --quiet plugin.js; then
                  ${git} add plugin.js
                  ${git} commit -m "Update plugin.js"
                else
                  echo "No changes in plugin.js"
                fi
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
              nixfmt
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
      }
    ))
    // {
      overlays.default = overlay;
      herculesCI.ciSystems = [ "x86_64-linux" ];
      effects = {
        runTests =
          let
            pkgs = import nixpkgs {
              system = "x86_64-linux";
              overlays = [ overlay ];
            };
            effectLib = hercules-ci-effects.lib.withPkgs pkgs;
          in
          effectLib.mkEffect {
            effectScript = pkgs.lib.getExe self.packages.x86_64-linux.yarnpnp2nix-test;
            inputs = with pkgs; [ nixVersions.nix_2_26 ];
            env.NIX_CONFIG = "extra-experimental-features = nix-command flakes";
            env.ROOT = "${self}";
          };
      };
    };
}
