{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      cache = import ./nix/cache.nix {inherit pkgs;};
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = [
          pkgs.zig_0_15
          pkgs.renameutils # qmv
          pkgs.coreutils
          pkgs.tree
        ];
      };

      packages.default = pkgs.stdenv.mkDerivation {
        pname = "clrn";
        version = "0.15.1";
        doCheck = false;
        src = ./.;

        nativeBuildInputs = with pkgs; [zig_0_15];

        buildPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
          ln -sf ${cache} $ZIG_GLOBAL_CACHE_DIR/p
          zig build -Doptimize=ReleaseSmall --summary all
        '';

        installPhase = ''
          install -Ds -m755 zig-out/bin/clrn $out/bin/clrn
        '';

        meta = with pkgs.lib; {
          description = "batch renaming for filesystem trees";
          platforms = platforms.linux;
          licence = licences.gpl3;
        };
      };
    });
}
