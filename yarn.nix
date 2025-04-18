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
    url = "https://github.com/yarnpkg/berry/archive/1908ee79fdf80fc8397d8ff928f3bfe25f30e715.tar.gz";
    sha256 = "sha256:znxB827TFLAEfCeHrwBsmRlkZz1LVWsBFhjZANiIW/4=";
  };

  phases = [
    "getSource"
    "patchPhase"
    "build"
  ];

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
    (cd packages/yarnpkg-pnp && yarn build:pnp:hook && yarn pack -o package.tgz)
    yarn build:cli
    mkdir -p $out/bin $out/packages
    mv packages/yarnpkg-cli/bundles/yarn.js $out/bin/yarn
    chmod +x $out/bin/yarn
    patchShebangs $out/bin/yarn
  '';
}
