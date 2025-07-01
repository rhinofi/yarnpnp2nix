#!/usr/bin/env bash

cp --no-preserve=mode -r "$ROOT" src
cd src

set -e

nix build -L ".#tests.patch" --no-link -L

pushd test

nix eval --json .#packages.aarch64-darwin.testa.transitiveRuntimePackages

nix build -L ".#testb"
./result/bin/testb

nix build -L ".#testa"
./result/bin/testa-peer-test

nix build -L ".#testb.package"
testbPackage=$(realpath ./result)/node_modules/testb

nix build -L ".#testb.shellRuntimeEnvironment"
runShellEnvironmentTest=$(realpath ./result)

pushd "$testbPackage"
"$runShellEnvironmentTest/bin/testa-test"
popd

nix develop ".#testb" -c bash <<EOF
cd $testbPackage
testa-test
EOF

echo "All tests passed successfully"
