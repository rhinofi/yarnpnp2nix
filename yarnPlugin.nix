{ stdenv, lib, yarnBerry, nodejs, writeShellApplication }:
let
  build = writeShellApplication {
    name = "build-yarn-plugin";
    runtimeInputs = [ yarnBerry nodejs ];
    text = builtins.readFile ./plugin/build.sh;
  };
in
stdenv.mkDerivation {
  name = "yarn-plugin-yarnpnp2nix.js";
  phases = [ "build" ];

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./plugin/sources/index.ts
      ./plugin/.yarnrc.yml
      ./plugin/.yarn/cache
      ./plugin/.yarn/patches
      ./plugin/package.json
      ./plugin/tsconfig.json
      ./plugin/yarn.lock
      ./plugin/.pnp.cjs
      ./plugin/.pnp.loader.mjs
      ./lib/getExistingManifest.nix.txt
    ];
  };
  build = ''
    tmpDir=$PWD
    cd $src/plugin

    export YARN_INSTALL_STATE_PATH=$tmpDir/install-state.gz
    ${lib.getExe build} --out-dir $tmpDir

    mv $tmpDir/@yarnpkg/* $out
  '';
}
