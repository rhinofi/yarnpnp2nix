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
    url = "https://github.com/yarnpkg/berry/archive/923f69827c77fe5cf4f6c28c0cab3c02a256abf0.tar.gz";
    sha256 = "sha256-pO89wh17cW9/RGKjo70yiefr+9nlJAQs4ZEdUnzdgQM=";
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
    (yarn.override { inherit nodejs; })
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
  meta.mainProgram = "yarn";
}
