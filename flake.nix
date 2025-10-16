{
  description = "sydradb reproducible dev/build (Zig pinned)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Optional: exact Zig versions via overlay
  inputs.zig-overlay.url = "github:mitchellh/zig-overlay";

  outputs = { self, nixpkgs, zig-overlay }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ zig-overlay.overlays.default ]; };
        zigPkgs = zig-overlay.packages.${system} or {};
        zigPinned = if builtins.hasAttr "zig-0.15.0" zigPkgs then zigPkgs."zig-0.15.0"
                    else if builtins.hasAttr "0.15.0" zigPkgs then zigPkgs."0.15.0"
                    else (pkgs.zig_0_15 or pkgs.zig);
      in f pkgs zigPinned);
  in {
    packages = forAllSystems (pkgs: zig: let
    in {
      default = pkgs.stdenvNoCC.mkDerivation {
        pname = "sydradb";
        version = self.rev or "dev";
        src = ./.;
        nativeBuildInputs = [ zig ];
        # Make Zig cache writable in Nix builds
        ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-cache";
        ZIG_LOCAL_CACHE_DIR = "$TMPDIR/zig-local-cache";
        buildPhase = ''
          zig build -Doptimize=ReleaseSafe
        '';
        installPhase = ''
          zig build -Doptimize=ReleaseSafe -p $out
        '';
      };
    });

    devShells = forAllSystems (pkgs: zig: let
      nixfmt = pkgs.nixfmt-classic or pkgs.nixfmt;
    in {
      default = pkgs.mkShell {
        packages = [ zig pkgs.zls pkgs.ripgrep pkgs.git nixfmt ];
        ZIG_GLOBAL_CACHE_DIR = ".zig-cache";
        ZIG_LOCAL_CACHE_DIR = ".zig-local-cache";
        shellHook = ''
          echo "sydradb dev shell with Zig $(${zig}/bin/zig version)" >&2
        '';
      };
    });

    formatter = forAllSystems (pkgs: pkgs.nixfmt-classic or pkgs.nixfmt);
  };
}
