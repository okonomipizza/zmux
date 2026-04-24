{
  lib,
  stdenv,
  callPackage,
  zig,
  ghosttySrc,
}: stdenv.mkDerivation (finalAttrs: {
  pname = "zmux";
  version = "0.0.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../build.zig
      ../build.zig.zon
    ];
  };

  deps = callPackage ../build.zig.zon.nix {
    name = "zmux-deps";
    inherit zig;
  };

  nativeBuildInputs = [zig];

  buildPhase = ''
    runHook preBuild
    mkdir -p zig-deps
    ln -s ${ghosttySrc} zig-deps/ghostty
    zig build \
      --system ${finalAttrs.deps} \
      -Doptimize=ReleaseSafe \
      --global-cache-dir $(pwd)/.cache
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp zig-out/bin/zmux $out/bin/
    runHook postInstall
  '';

  meta = {
    description = "Terminal multiplexer written in Zig";
    license = lib.licenses.mit;
    platforms = ["x86_64-linux" "aarch64-linux"];
    mainProgram = "zmux";
  };
})
