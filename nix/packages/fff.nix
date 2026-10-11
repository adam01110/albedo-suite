{
  # keep-sorted start
  autoPatchelfHook,
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenv,
  # keep-sorted end
}: let
  version = "0.11.0";
  ffiVersion = "1.3.7";
  arch =
    {
      # keep-sorted start
      aarch64-linux = "arm64";
      x86_64-linux = "x64";
      # keep-sorted end
    }
    .${
      stdenv.hostPlatform.system
    } or (throw "albedo-fff: unsupported platform ${stdenv.hostPlatform.system}");

  fffNode = fetchurl {
    url = "https://registry.npmjs.org/@ff-labs/fff-node/-/fff-node-${version}.tgz";
    hash = "sha512-/7fX4kgy28pFZghxuXCAcIPQKb2+VqVirpFcDqMKgrFLTz56tVzHjOkFSdKGq7fa6wRb6eS5Dg9SaX1qyCcKxQ==";
  };
  ffiRs = fetchurl {
    url = "https://registry.npmjs.org/ffi-rs/-/ffi-rs-${ffiVersion}.tgz";
    hash = "sha512-5MMZQS2t/6f/ec3sx0f51gBcKGZPGfolPAW04lvLOSYnr7gmOKs8YzH1Rh+34WGO+VtcgcTuxaUUoJLcR4Tirg==";
  };
  fffBin = fetchurl {
    url = "https://registry.npmjs.org/@ff-labs/fff-bin-linux-${arch}-gnu/-/fff-bin-linux-${arch}-gnu-${version}.tgz";
    hash =
      {
        # keep-sorted start
        arm64 = "sha512-wOTyNzovqN1+Kg3kPqfKqZ2+A262Um4bHrEIeAwKU9R7YoyMXI9oo6DTbEl2ullF3G01FaBt/PPHOZYi1q8ubw==";
        x64 = "sha512-MJ1AJz9c5kxdTiIhmlEwA+hw57vBDoa+VQSr4F+1inaEiFDtem7EnXE1P8Bdhf4okGM557mCXgRrvCt4kM5pSg==";
        # keep-sorted end
      }.${
        arch
      };
  };
  ffiBin = fetchurl {
    url = "https://registry.npmjs.org/@yuuang/ffi-rs-linux-${arch}-gnu/-/ffi-rs-linux-${arch}-gnu-${ffiVersion}.tgz";
    hash =
      {
        # keep-sorted start
        arm64 = "sha512-nrW4MlFlyQInfxTsI5wtcIpbV4KlHLWo2BCk4CHIETlUT+PUspNFqDg+Byy7My3hpCZlXp0WsMVP/3N0LlybNw==";
        x64 = "sha512-upEz1Q98T51x2In872fsjgHCJbE3e8r9JxhJD+5NvSMk6BpieYWRodTbsMxV6oKWmfl12loKwF2j4OBSWKl0lA==";
        # keep-sorted end
      }.${
        arch
      };
  };
  fffLicense = fetchurl {
    url = "https://raw.githubusercontent.com/dmtrKovalenko/fff/v${version}/LICENSE";
    hash = "sha256-+CZN6C2xiINKVxHX40jcCMM9sU95u1h8y0Jhb9aU7oE=";
  };
in
  stdenv.mkDerivation {
    pname = "albedo-fff";
    inherit version;

    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [
      # keep-sorted start
      autoPatchelfHook
      makeWrapper
      nodejs
      # keep-sorted end
    ];
    buildInputs = [stdenv.cc.cc.lib];

    installPhase = ''
      runHook preInstall
      modules=$out/lib/node_modules
      mkdir -p "$modules/@ff-labs/fff-node" "$modules/@ff-labs/fff-bin-linux-${arch}-gnu" "$modules/ffi-rs" "$modules/@yuuang/ffi-rs-linux-${arch}-gnu"
      mkdir -p "$out/libexec" "$out/share/licenses/albedo-fff" "$out/bin"
      tar xzf ${fffNode} -C "$modules/@ff-labs/fff-node" --strip-components=1
      tar xzf ${fffBin} -C "$modules/@ff-labs/fff-bin-linux-${arch}-gnu" --strip-components=1
      tar xzf ${ffiRs} -C "$modules/ffi-rs" --strip-components=1
      tar xzf ${ffiBin} -C "$modules/@yuuang/ffi-rs-linux-${arch}-gnu" --strip-components=1
      cp ${../../src/server/priv/python/albedo_fff.mjs} "$out/libexec/albedo-fff.mjs"
      cp ${fffLicense} "$out/share/licenses/albedo-fff/fff-LICENSE"
      cp "$modules/ffi-rs/LICENSE" "$out/share/licenses/albedo-fff/ffi-rs-LICENSE"
      makeWrapper ${nodejs}/bin/node "$out/bin/albedo-fff" --add-flags "$out/libexec/albedo-fff.mjs" --prefix NODE_PATH : "$modules"
      runHook postInstall
    '';

    doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
    installCheckPhase = ''
      runHook preInstallCheck
      mkdir -p fixture
      printf '%s\n' FFF_PACKAGE_NEEDLE > fixture/needle.txt
      TEST_FIXTURE="$PWD/fixture" NODE_PATH="$out/lib/node_modules" ${nodejs}/bin/node <<'JS'
      const assert = require('node:assert/strict');
      const { FileFinder, binaryExists } = require('@ff-labs/fff-node');
      async function main() {
        assert.equal(binaryExists(), true);
        const created = FileFinder.create({ basePath: process.env.TEST_FIXTURE, watch: false });
        assert.equal(created.ok, true, created.error);
        const finder = created.value;
        try {
          const scan = await finder.waitForScan(5000);
          assert.equal(scan.ok, true, scan.error);
          const found = finder.fileSearch('needle.txt');
          assert.equal(found.ok, true, found.error);
          assert(found.value.items.some(item => item.relativePath === 'needle.txt'));
          const matches = finder.grep('FFF_PACKAGE_NEEDLE', { mode: 'plain' });
          assert.equal(matches.ok, true, matches.error);
          assert(matches.value.items.some(item => item.relativePath === 'needle.txt'));
        } finally {
          finder.destroy();
        }
      }
      main().catch(error => { console.error(error); process.exitCode = 1; });
      JS
      runHook postInstallCheck
    '';

    meta = {
      description = "FFF native file indexer worker for Albedo";
      homepage = "https://github.com/dmtrKovalenko/fff";
      license = lib.licenses.mit;
      platforms = [
        # keep-sorted start
        "aarch64-linux"
        "x86_64-linux"
        # keep-sorted end
      ];
      mainProgram = "albedo-fff";
    };
  }
