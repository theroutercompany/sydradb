{
  description = "sydradb reproducible dev/build (Zig pinned)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
  in {
    packages = forAllSystems (pkgs: let
      zig = pkgs.zig_0_15 or pkgs.zig;
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

    devShells = forAllSystems (pkgs: let
      zig = pkgs.zig_0_15 or pkgs.zig;
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

