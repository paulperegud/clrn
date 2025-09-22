{ pkgs, ... }:
let

  outputHash =
    if pkgs.stdenv.isDarwin then
      "sha256-JevYJ+LZ2trt/EU9UHv3MehtgwcDKQs5CwNL3nnEqPc="
    else
      "sha256-zjfu6+Tyji/41vLm0RBMDMUzlINEoWOm4CqOxJOTZQs=";
in
pkgs.stdenv.mkDerivation {
  pname = "clrn-cache";
  version = "0.15.1";
  doCheck = false;
  src = ../.;

  nativeBuildInputs = with pkgs; [zig];

  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
    zig build --fetch --summary none
  '';

  installPhase = ''
    mv $ZIG_GLOBAL_CACHE_DIR/p $out
  '';

  inherit outputHash;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
}
