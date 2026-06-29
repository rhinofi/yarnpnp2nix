{
  stdenv,
  rsync,
  yarn,
  fetchzip,
  nodejs,
}:

stdenv.mkDerivation {
  name = "yarn-berry";
  src = fetchzip {
    url = "https://github.com/yarnpkg/berry/archive/352c4d67f4ba49a2aefd28cff98c61d88a5a5ac1.tar.gz";
    sha256 = "sha256-5JH5k2ara3fzKwtDXUy5HIgztoAM4lMfs3f/DzncIoA=";
  };

  phases = [
    "getSource"
    "patchPhase"
    "build"
  ];

  patches = [
    ./yarnPatches/pack-specific-project.patch
    ./yarnPatches/checksums-for-conditional-locator.patch
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
