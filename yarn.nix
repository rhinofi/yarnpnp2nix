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
    url = "https://github.com/yarnpkg/berry/archive/8452bc2b89e8cad69895d4fc8ba5f4363c7f0dcf.tar.gz";
    sha256 = "sha256-irrXN5EgOm2vjAw9qZKfrvF1Joa/E5QDA3kBVhw4TaQ=";
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
