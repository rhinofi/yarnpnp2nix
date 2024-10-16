{ stdenv, rsync, yarn, fetchzip, nodejs }:

stdenv.mkDerivation {
  name = "yarn-berry";
  src = builtins.fetchTarball {
    url = "https://github.com/yarnpkg/berry/archive/refs/tags/@yarnpkg/cli/4.5.0.tar.gz";
    sha256 = "sha256:0dqklcc0clfkv6l4d2vlhh2icamm5a16kah4y4c5k3r0h598ac1r";
  };

  phases = [ "getSource" "patchPhase" "build" ];

  patches = [
    ./yarnPatches/pack-specific-project.patch
    ./yarnPatches/node-22-experimental-require-module-support.patch
  ];

  buildInputs = [
    yarn
    rsync
    nodejs
  ];

  getSource = ''
    tmpDir=$PWD
    mkdir -p $tmpDir/yarn
    shopt -s dotglob
    cp --no-preserve=mode -r $src/* $tmpDir/yarn/
    cd $tmpDir/yarn
  '';

  build = ''
    (cd packages/yarnpkg-pnp && yarn build:pnp:hook && yarn pack -o package.tgz)
    yarn build:cli
    mkdir -p $out/bin $out/packages
    mv packages/yarnpkg-cli/bundles/yarn.js $out/bin/yarn
    chmod +x $out/bin/yarn
    patchShebangs $out/bin/yarn
  '';
}
