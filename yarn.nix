{ stdenv, rsync, yarn, fetchzip, nodejs }:

stdenv.mkDerivation {
  name = "yarn-berry";
  src = builtins.fetchTarball {
    url = "https://github.com/yarnpkg/berry/archive/@yarnpkg/cli/4.0.0-rc.45.tar.gz";
    sha256 = "sha256:1napnx8hlz96jixsn6z06viad76kb9jdm8xij72zc4bl7zybifr7";
  };

  phases = [ "getSource" "patchPhase" "build" ];

  patches = [
    ./yarnPatches/pack-specific-project.patch
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
    yarn build:cli
    (cd packages/yarnpkg-pnp && yarn pack -o package.tgz)
    mkdir -p $out/bin $out/packages
    mv packages/yarnpkg-cli/bundles/yarn.js $out/bin/yarn
    chmod +x $out/bin/yarn
    patchShebangs $out/bin/yarn
  '';
}
