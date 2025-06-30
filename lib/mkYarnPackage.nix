{ defaultPkgs, lib }:

with lib;

let
  nixPlugin = defaultPkgs.callPackage ../yarnPlugin.nix { };
  yarnBin = "${defaultPkgs.yarnBerry}/bin/yarn";

  yarnEnvVars = [
    "YARN_PLUGINS=${nixPlugin}"
    "YARN_PNP_ZIP_BACKEND=js"
  ];
  yarnEnvVarsOneLine = lib.concatStringsSep " " yarnEnvVars;
  setupYarnBinScript = ''
    export ${yarnEnvVarsOneLine}
  '';

  nullableAttrOr =
    default: name: attrs:
    let
      value = attrs.${name} or null;
    in
    if value == null then default else value;
  hasAttrNotNull =
    name: attrs:
    let
      value = attrs.${name} or null;
    in
    value != null;
  resolvePkg =
    pkg:
    if pkg ? "canonicalPackage" then
      (
        pkg.canonicalPackage
        // (lib.optionalAttrs (pkg ? dependencies) { inherit (pkg) dependencies; })
        // (lib.optionalAttrs (pkg ? devDependencies) { inherit (pkg) devDependencies; })
      )
    else
      pkg;

  makePkgRef = pkg: "${pkg.name}@${pkg.reference}";

  mkYarnPackagesFromManifest =
    {
      pkgs ? defaultPkgs,
      yarnManifest,
      packageOverrides ? { },
    }:
    let
      mergedManifest = applyPackageOverrides {
        inherit yarnManifest;
        inherit packageOverrides;
      };
      allPackageData = buildPackageDataFromYarnManifest {
        inherit pkgs;
        yarnManifest = mergedManifest;
      };
    in
    mapAttrs (
      key: value:
      mkYarnPackageFromManifest_internal {
        package = key;
        inherit pkgs;
        yarnManifest = mergedManifest;
        inherit allPackageData;
      }
    ) yarnManifest;

  rewritePackageRef = pkg: allPackages: allPackages.${makePkgRef pkg};

  applyPackageOverrides =
    {
      yarnManifest,
      packageOverrides,
    }:
    let
      merged = mapAttrs (
        key: packageManifest:
        let
          mergedPackage =
            if packageOverrides ? ${key} then
              let
                overridesAsAttrsOrFunc = packageOverrides."${key}";
                overridesAsAttrs =
                  if builtins.isFunction overridesAsAttrsOrFunc then
                    overridesAsAttrsOrFunc packageManifest
                  else
                    overridesAsAttrsOrFunc;
              in
              recursiveUpdate packageManifest overridesAsAttrs
            else
              packageManifest;
        in
        mergedPackage
        // (lib.optionalAttrs (mergedPackage ? canonicalPackage) {
          canonicalPackage = rewritePackageRef mergedPackage.canonicalPackage merged;
        })
        // (lib.optionalAttrs (mergedPackage ? dependencies) {
          dependencies = mapAttrs (__: pkg: rewritePackageRef pkg merged) mergedPackage.dependencies;
        })
        // (lib.optionalAttrs (mergedPackage ? devDependencies) {
          devDependencies = mapAttrs (__: pkg: rewritePackageRef pkg merged) mergedPackage.devDependencies;
        })
      ) yarnManifest;
    in
    merged;

  mkCreateLockFileScript_internal =
    {
      packageRegistry,
      locatorString,
    }:
    let
      packageRegistryJSON = builtins.toJSON packageRegistry;

      # Bit of a HACK, builtins.toFile cannot contain a string with references to /nix/store paths,
      # so we extract the "context" (which is a reference to any /nix/store paths in the JSON), then remove
      # the context from the string and write the resulting string to disk using builtins.toFile.
      # We then manually append the context which contains the references to the /nix/store paths
      # to `createLockFileScript` so when the script is used, any npm dependency /nix/store paths
      # are built and realised.
      packageRegistryContext = builtins.getContext packageRegistryJSON;

      packageRegistryFile = builtins.toFile "yarn-package-registry.json" (
        # unsafeDiscardStringContext is undocumented
        # https://github.com/NixOS/nix/blob/ac0fb38e8a5a25a84fa17704bd31b453211263eb/src/libexpr/primops/context.cc#L8
        builtins.unsafeDiscardStringContext packageRegistryJSON
      );

      createPackageRegistryData = builtins.appendContext ''
        cat ${packageRegistryFile} | ${defaultPkgs.jq}/bin/jq -rcM \
          --arg packageLocation "$packageLocation" \
          --arg locatorString ${builtins.toJSON locatorString} \
          '.[$locatorString].packageLocation = $packageLocation' > $tmpDir/packageRegistryData.json
      '' packageRegistryContext;

      createLockFileScript = ''
        ${createPackageRegistryData}

        ${yarnBin} nix create-lockfile $tmpDir/packageRegistryData.json
      '';
    in
    {
      inherit createPackageRegistryData createLockFileScript;
    };

  mkYarnPackage_internal =
    {
      pkgs,
      name,
      outputName ? name,
      src ? null,
      packageManifest,
      allPackageData,
      nodejsPackage,
      build ? "",
      buildInputs ? [ ],
      nativeBuildInputs ? [ ],
      preInstallScript ? "",
      postInstallScript ? "",
      __noChroot ? null,
    }:
    let
      nodeBin = "${nodejsPackage}/bin/node";
      finalDerivationOverrides = packageManifest.finalDerivationOverrides or { };
      shouldBeUnplugged = packageManifest.shouldBeUnplugged or false;
      locatorString = "${name}@${reference}";
      reference = packageManifest.reference;
      bin = packageManifest.bin or null;
      # This is useful when binaries are self contained and have no runtime deps,
      # for examplet when they are bundled
      disablePnpInBinWrappers = packageManifest.disablePnpInBinWrappers or false;
      useMjsLoader = packageManifest.useMjsLoader or true;

      _platformOutputHash = lib.mapNullable (
        outputHashByPlatform: outputHashByPlatform."${pkgs.stdenv.system}" or ""
      ) (packageManifest.outputHashByPlatform or null);
      _outputHash = packageManifest.outputHash or null;
      outputHash = if _platformOutputHash != null then _platformOutputHash else _outputHash;

      isSourceTgz = src != null && (last (splitString "." src)) == "tgz";
      isSourcePatch = src != null && (substring 0 6 reference) == "patch:";

      willFetch = src == null || isSourcePatch || isSourceTgz;
      willBuild = !willFetch;
      willOutputBeZip = src == null && shouldBeUnplugged == false;

      locatorJSON = builtins.toJSON (
        builtins.toJSON {
          name = packageManifest.flatName;
          scope = packageManifest.scope;
          reference = packageManifest.reference;
        }
      );

      locatorToFetchJSON = builtins.toJSON (
        builtins.toJSON {
          name = packageManifest.flatName;
          scope = packageManifest.scope;
          reference =
            if isSourcePatch then (head (splitString "#" reference)) + "#${src}" else packageManifest.reference;
        }
      );

      packageRegistry = buildPackageRegistry {
        inherit pkgs;
        topLevel = packageManifest;
        inherit allPackageData;
      };

      inherit
        (mkCreateLockFileScript_internal {
          inherit packageRegistry;
          inherit locatorString;
        })
        createLockFileScript
        createPackageRegistryData
        ;

      createShellRuntimeEnvironment =
        {
          name,
          createLockFileScript,
          dependencyBins,
        }:
        pkgs.stdenv.mkDerivation {
          inherit name;
          phases = [ "generateRuntimePhase" ];

          buildInputs = [
            defaultPkgs.yarnBerry
            nodejsPackage
          ];

          generateRuntimePhase = ''
            tmpDir=$TMPDIR
            ${setupYarnBinScript}

            packageLocation="/"
            packageDrvLocation="/"
            ${createLockFileScript}

            mkdir -p $out/bin
            cp $tmpDir/yarn.lock $out
            cp $tmpDir/packageRegistryData.json $out

            ${concatStringsSep "\n" (
              mapAttrsToList (
                binKey:
                { pkg, binScript }:
                ''
                  cat << EOF > $out/bin/${binKey}
                  #!${pkgs.bashInteractive}/bin/bash

                  pnpDir="\$(mktemp -d)"
                  (cd $out && ${yarnEnvVarsOneLine} ${yarnBin} nix generate-pnp-file \$pnpDir $out/packageRegistryData.json "${locatorString}")
                  binPackageLocation="\$(${nodeBin} -r \$pnpDir/.pnp.cjs -e 'console.log(require("pnpapi").getPackageInformation({ name: process.argv[1], reference: process.argv[2] })?.packageLocation)' "${pkg.name}" "${pkg.reference}")"

                  export PATH="${nodejsPackage}/bin:\''$PATH"

                  nodeOptions="--require \$pnpDir/.pnp.cjs --loader ${./.pnp.loader.mjs}"
                  export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"

                  exec ${nodeBin} \$binPackageLocation./${binScript} "\$@"
                  EOF
                  chmod +x $out/bin/${binKey}
                ''
              ) dependencyBins
            )}
          '';
        };

      packageRegistryRuntimeOnly = buildPackageRegistry {
        inherit pkgs;
        topLevel = packageManifest;
        inherit allPackageData;
        excludeDevDependencies = true;
      };

      createLockFileScriptForRuntime =
        (mkCreateLockFileScript_internal {
          packageRegistry = packageRegistryRuntimeOnly;
          inherit locatorString;
        }).createLockFileScript;

      makeFetchOnlyDerivation =
        outputHash:
        pkgs.stdenv.mkDerivation {
          name = outputName + (if willOutputBeZip then ".zip" else "");
          phases = [ "fetchPhase" ];
          outputHashMode = "flat";
          outputHashAlgo = "sha512";
          outputHash = outputHash;

          buildInputs = with pkgs; [
            defaultPkgs.yarnBerry
            unzip
            git
            cacert
            nodejs
          ];

          fetchPhase = ''
            set -euo pipefail
            tmpDir=$PWD
            ${setupYarnBinScript}
            touch yarn.lock
            echo locatorToFetchJSON: ${locatorToFetchJSON}

            export HOME="$tmpDir/fake-home"
            mkdir -p "$HOME"
            ${
              if isSourceTgz then
                "${yarnBin} nix convert-to-zip ${locatorToFetchJSON} ${src} $tmpDir/output.zip"
              else
                "${yarnBin} nix fetch-by-locator ${locatorToFetchJSON} $tmpDir"
            }
            mv $tmpDir/output.zip $out
          '';
        };
      set_packageLocation_create_packageRegistryData_lockFile_and_pnp = packageLocation: ''
        packageLocation="${packageLocation}"
        mkdir -p $packageLocation
        ${createLockFileScript}
        ${yarnBin} nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"
        cp --no-preserve=mode "${./.pnp.loader.mjs}" $out/.pnp.loader.mjs
      '';
      unpluggedDerivation = pkgs.stdenv.mkDerivation {
        name = outputName + (if willOutputBeZip then ".zip" else "");
        phases =
          (lib.optionals willBuild [
            "buildPhase"
            "packPhase"
          ])
          ++ [ (if shouldBeUnplugged then "unplugPhase" else "movePhase") ];

        inherit __noChroot;

        buildInputs =
          with pkgs;
          [
            defaultPkgs.yarnBerry
            nodejsPackage
            unzip
          ]
          ++ (
            if stdenv.isDarwin then
              [
                xcbuild
              ]
            else
              [ ]
          )
          ++ buildInputs;
        inherit nativeBuildInputs;
        buildPhase =
          if willBuild && build != "" then
            ''
              tmpDir=$PWD
              ${setupYarnBinScript}

              ${set_packageLocation_create_packageRegistryData_lockFile_and_pnp "$out/tmp/${name}"}

              cp -rT ${src} $packageLocation
              chmod -R +w $packageLocation

              mkdir -p $tmpDir/wrappedbins
              ${yarnBin} nix make-path-wrappers $tmpDir/wrappedbins $out $tmpDir/packageRegistryData.json "${locatorString}"

              cd $packageLocation
              nodeOptions="--require $out/.pnp.cjs --loader $out/.pnp.loader.mjs"
              oldNodeOptions="$NODE_OPTIONS"
              oldPath="$PATH"
              export NODE_OPTIONS="$NODE_OPTIONS $nodeOptions"
              export PATH="$PATH:$tmpDir/wrappedbins"

              ${build}

              export NODE_OPTIONS="$oldNodeOptions"
              export PATH="$oldPath"
              cd $tmpDir
            ''
          else
            " ";

        packPhase =
          if willBuild then
            ''
              tmpDir=$PWD
              ${setupYarnBinScript}

              ${
                if build != "" then
                  ''
                    export YARNNIX_PACK_DIRECTORY="$packageLocation"
                  ''
                else
                  ''
                    touch yarn.lock
                    packageLocation=$out/node_modules/${name}
                    ${createPackageRegistryData}
                    export YARNNIX_PACK_DIRECTORY="${src}"
                  ''
              }

              export YARNNIX_PACKAGE_REGISTRY_DATA_PATH="$tmpDir/packageRegistryData.json"

              ${yarnBin} pack -o $tmpDir/package.tgz
              ${yarnBin} nix convert-to-zip ${locatorJSON} $tmpDir/package.tgz $tmpDir/output.zip

              ${if build != "" then "rm -rf $out" else ""}
            ''
          else
            " ";

        unplugPhase =
          # for debugging:
          # cp ${./pnptemp.cjs} $out/.pnp.cjs
          # sed -i "s!__PACKAGE_PATH_HERE__!$packageLocation/!" $out/.pnp.cjs
          if shouldBeUnplugged then
            ''
              tmpDir=$PWD
              mkdir -p $out

              ${
                if willFetch then
                  ''
                    pkg_src=${makeFetchOnlyDerivation outputHash}
                    ${setupYarnBinScript}
                    touch yarn.lock
                  ''
                else
                  ''
                    pkg_src=$tmpDir/output.zip
                  ''
              }

              unzip -qq -d $out $pkg_src

              ${set_packageLocation_create_packageRegistryData_lockFile_and_pnp "$out/node_modules/${name}"}

              # create dummy home directory in case any build scripts need it
              export HOME=$tmpDir/home
              mkdir -p $HOME

              ${preInstallScript}
              ${yarnBin} nix run-build-scripts ${locatorJSON} $out $packageLocation

              cd $packageLocation
              ${postInstallScript}

              # create a .ready file so the output matches what yarn unplugs itself
              # (useful if we want to be able to generate hash for unplugged output automatically)
              touch .ready

              # if a node_modules folder was created INSIDE an unplugged package, it was probably used for caching
              # purposes, so we can just remove it. In the offchance that this breaks something, the user
              # can just specify an outputHash manually in packageOverrides
              rm -rf node_modules || true

              # remove .pnp.cjs here as it will break Nix (see bug below), it's okay because we recreate it later
              # in finalDerivation
              rm $out/.pnp.cjs
              rm $out/.pnp.loader.mjs

              # set executable bit with chmod for all bin scripts
              ${concatStringsSep "\n" (
                mapAttrsToList (binKey: binScript: ''
                  chmod +x $out/node_modules/${name}/${binScript}
                  patchShebangs $out/node_modules/${name}/${binScript}
                '') (if bin != null then bin else { })
              )}
            ''
          else
            " ";

        movePhase =
          if !shouldBeUnplugged then
            ''
              # won't be unplugged, so move zip file to output
              mv $tmpDir/output.zip $out
            ''
          else
            " ";
      };
      packageDerivation =
        if shouldBeUnplugged then unpluggedDerivation else makeFetchOnlyDerivation outputHash;
      # have a separate derivation that includes the .pnp.cjs and wrapped bins
      # as Nix is unable to shasum the derivation $out if it contains files that contain /nix/store paths
      # to other derivations that are fixed output derivations.
      # works around:
      # https://github.com/NixOS/nix/issues/6660
      # https://github.com/NixOS/nix/issues/7148 (maybe)
      # without this workaround we get error: unexpected end-of-file errors
      finalDerivation =
        pkgs.stdenv.mkDerivation
          # Apply overrides from packageOverrides
          (recursiveUpdate finalDerivationAttrs finalDerivationOverrides);
      finalDerivationAttrs = {
        name = outputName;
        phases = [ "generateRuntimePhase" ] ++ (lib.optional (bin != null) "wrapBinPhase");

        buildInputs = [
          defaultPkgs.yarnBerry
          nodejsPackage
        ];

        generateRuntimePhase = ''
          tmpDir=$PWD
          ${setupYarnBinScript}

          packageLocation=${packageDerivation}/node_modules/${name}
          packageDrvLocation=${packageDerivation}
          ${createLockFileScriptForRuntime}

          mkdir -p $out
          ${yarnBin} nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"
          cp --no-preserve=mode "${./.pnp.loader.mjs}" $out/.pnp.loader.mjs
        '';

        wrapBinPhase =
          if bin != null then
            ''
              mkdir -p $out/bin

              ${concatStringsSep "\n" (
                mapAttrsToList (binKey: binScript: ''
                  cat << EOF > $out/bin/${binKey}
                  #!${pkgs.bashInteractive}/bin/bash
                  ${
                    if disablePnpInBinWrappers then
                      ""
                    else
                      ''
                        nodeOptions="--require $out/.pnp.cjs${lib.optionalString useMjsLoader " --loader $out/.pnp.loader.mjs"}"
                        export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"
                        export PATH="${nodejsPackage}/bin:\''$PATH"
                      ''
                  }
                  ${
                    if shouldBeUnplugged then
                      ''exec ${packageDerivation}/node_modules/${name}/${binScript} "\$@"''
                    else
                      ''exec node ${packageDerivation}/node_modules/${name}/${binScript} "\$@"''
                  }
                  EOF
                  chmod +x $out/bin/${binKey}
                '') bin
              )}
            ''
          else
            " ";

        shellHook = ''
          tmpDir=$TMPDIR
          ${setupYarnBinScript}

          packageLocation="/"
          packageDrvLocation="/"
          (cd $tmpDir && ${createLockFileScript})
          (cd $tmpDir && ${yarnBin} nix generate-pnp-file $tmpDir $tmpDir/packageRegistryData.json "${locatorString}")

          nodeOptions="--require $TMPDIR/.pnp.cjs"
          export NODE_OPTIONS="$NODE_OPTIONS $nodeOptions"

          mkdir -p $tmpDir/wrappedbins
          ${yarnBin} nix make-path-wrappers $tmpDir/wrappedbins $tmpDir $tmpDir/packageRegistryData.json "${locatorString}"
          export PATH="$PATH:$tmpDir/wrappedbins"
        '';
      };

      dependencyBins = listToAttrs (
        concatMap (
          pkg:
          mapAttrsToList (binKey: binScript: {
            name = binKey;
            value = {
              inherit pkg;
              inherit binScript;
            };
          }) ((resolvePkg pkg).bin or { })
        ) (mapAttrsToList (__: dep: dep) (packageManifest.dependencies or { }))
      );

      devDependencyBins = listToAttrs (
        concatMap (
          pkg:
          mapAttrsToList (binKey: binScript: {
            name = binKey;
            value = {
              inherit pkg;
              inherit binScript;
            };
          }) ((resolvePkg pkg).bin or { })
        ) (mapAttrsToList (__: dep: dep) (packageManifest.devDependencies or { }))
      );

      shellRuntimeEnvironment = createShellRuntimeEnvironment {
        name = outputName + "-shell-environment";
        createLockFileScript = createLockFileScriptForRuntime;
        dependencyBins = dependencyBins;
      };

      shellRuntimeDevEnvironment = createShellRuntimeEnvironment {
        name = outputName + "-shell-dev-environment";
        createLockFileScript = createLockFileScript;
        dependencyBins = devDependencyBins // dependencyBins;
      };
    in
    finalDerivation
    // {
      package = packageDerivation;
      manifest = packageManifest;
      transitiveRuntimePackages = filter (pkg: pkg != null) (
        mapAttrsToList (
          key: pkg: if pkg != null && !isString pkg.drvPath then pkg.drvPath.binDrvPath else null
        ) packageRegistryRuntimeOnly
      );
      inherit shellRuntimeEnvironment;
      inherit shellRuntimeDevEnvironment;
      # for debugging with nix eval
      inherit packageRegistry;
    };

  mkYarnPackageFromManifest_internal =
    {
      package,
      pkgs,
      yarnManifest,
      allPackageData,
    }:
    let
      packageManifest = yarnManifest."${package}";
    in
    mkYarnPackageFromPackageManifest_internal {
      inherit packageManifest;
      inherit pkgs;
      inherit yarnManifest;
      inherit allPackageData;
    };

  mkYarnPackageFromPackageManifest_internal =
    {
      packageManifest,
      pkgs,
      allPackageData,
      # Unused but expected
      yarnManifest,
    }:
    (makeOverridable mkYarnPackage_internal {
      inherit pkgs;
      nodejsPackage = packageManifest.nodejsPackage or pkgs.nodejs;
      inherit (packageManifest) name outputName;
      inherit packageManifest;
      inherit allPackageData;
      src = packageManifest.src or null;
      build = packageManifest.build or "";
      buildInputs = packageManifest.buildInputs or [ ];
      preInstallScript = packageManifest.preInstallScript or "";
      postInstallScript = packageManifest.postInstallScript or "";
      nativeBuildInputs = packageManifest.nativeBuildInputs or [ ];
      __noChroot = packageManifest.__noChroot or null;
    });

  mapDepsAttrValuesToTuples = mapAttrs (
    name: depPkg: [
      depPkg.name
      depPkg.reference
    ]
  );

  getAllDependencies =
    {
      excludeDevDependencies ? false,
      filterDependencies ? null,
    }:
    pkg:
    let
      deps = nullableAttrOr { } "dependencies" pkg;
      devDeps = nullableAttrOr { } "devDependencies" pkg;
      all = deps // (if excludeDevDependencies then { } else devDeps);
      filteredDeps =
        # TODO: why do we only filter when excludeDevDependencies is true?
        # this is original logic be we migth want to revise.
        if filterDependencies == null || !excludeDevDependencies then
          all
        else
          filterAttrs (name: v: filterDependencies name) all;
    in
    filteredDeps;

  buildPackageDataFromYarnManifest =
    {
      pkgs,
      yarnManifest,
    }:
    let
      getPackageDataForPackage =
        pkg:
        let
          resolvedPkg = resolvePkg pkg;
        in
        if
          (hasAttrNotNull "installCondition" resolvedPkg)
          && (resolvedPkg.installCondition pkgs.stdenv) == false
        then
          null
        else
          let
            drv = mkYarnPackageFromPackageManifest_internal {
              inherit pkgs;
              inherit yarnManifest;
              packageManifest = resolvedPkg;
              inherit allPackageData;
            };
            drvForVirtual = mkYarnPackageFromPackageManifest_internal {
              inherit pkgs;
              inherit yarnManifest;
              packageManifest = resolvedPkg // {
                dependencies = pkg.dependencies or { };
                devDependencies = pkg.devDependencies or { };
              };
              inherit allPackageData;
            };
          in
          {
            inherit pkg;
            inherit (pkg) name reference;
            canonicalReference = resolvedPkg.reference;
            inherit (resolvedPkg) linkType;
            filterDependencies = resolvedPkg.filterDependencies or null;
            manifest = lib.removeAttrs resolvedPkg [
              "src"
              "installCondition"
              "dependencies"
              "devDependencies"
              "filterDependencies"
              "name"
              "reference"
            ];
            inherit drv;
            inherit drvForVirtual;
            packageDependencies = mapDepsAttrValuesToTuples (getAllDependencies { } pkg);
          };

      allPackageData = mapAttrs (__: pkg: getPackageDataForPackage pkg) yarnManifest;
    in
    allPackageData;

  buildPackageRegistry =
    {
      pkgs,
      topLevel,
      allPackageData,
      excludeDevDependencies ? false,
    }:
    let
      topLevelRef = makePkgRef topLevel;
      getPackageDataForPackage =
        pkgRef:
        let
          data = allPackageData.${pkgRef};
        in
        lib.mapNullable (data: {
          inherit (data)
            name
            reference
            canonicalReference
            linkType
            manifest
            ;
          drvPath = data.drv.package // {
            binDrvPath = data.drv;
          };
          packageDependencies =
            if !excludeDevDependencies then
              data.packageDependencies
            else
              mapDepsAttrValuesToTuples (
                getAllDependencies {
                  inherit excludeDevDependencies;
                  filterDependencies = data.filterDependencies or null;
                } data.pkg
              );
        }) data;
      topLevelPackageData =
        if
          (hasAttrNotNull "installCondition" topLevel) && (topLevel.installCondition pkgs.stdenv) == false
        then
          null
        else
          {
            inherit (topLevel) name reference linkType;
            canonicalReference = topLevel.reference;
            manifest = lib.removeAttrs topLevel [
              "src"
              "installCondition"
              "dependencies"
              "devDependencies"
              "filterDependencies"
            ];
            drvPath = "/dev/null"; # if package is toplevel package then the location is determined in the buildPhase as it will be $out
            packageDependencies = mapDepsAttrValuesToTuples (
              getAllDependencies {
                inherit excludeDevDependencies;
                filterDependencies = topLevel.filterDependencies or null;
              } topLevel
            );
          };
      # thanks to https://github.com/NixOS/nix/issues/552#issuecomment-971212372
      # for documentation and a good example on how builtins.genericClosure works
      allTransitiveDependencies = builtins.genericClosure {
        startSet = [
          {
            key = topLevelRef;
            pkg = topLevel;
          }
        ];
        operator =
          { pkg, ... }:
          let
            deps = getAllDependencies {
              inherit excludeDevDependencies;
              filterDependencies = (resolvePkg pkg).filterDependencies or null;
            } pkg;
            depNames = attrNames deps;
            mapDepName =
              depName:
              let
                pkg = deps.${depName};
                key = makePkgRef pkg;
              in
              {
                inherit pkg key;
              };
          in
          map mapDepName depNames;
      };
      packageRegistryData = listToAttrs (
        map (
          { key, ... }:
          let
            package = if key == topLevelRef then topLevelPackageData else getPackageDataForPackage key;
          in
          {
            name = key;
            value = package;
          }
        ) allTransitiveDependencies
      );
    in
    packageRegistryData;
in
{
  inherit mkYarnPackagesFromManifest;
}
