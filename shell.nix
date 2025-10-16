{ pkgs ? import <nixpkgs> {} }:

let
  zig = if pkgs ? zig_0_15 then pkgs.zig_0_15 else pkgs.zig;
  nixfmt = if pkgs ? nixfmt-classic then pkgs.nixfmt-classic else pkgs.nixfmt;
in pkgs.mkShell {
  packages = [ zig pkgs.zls pkgs.ripgrep pkgs.git nixfmt ];

  ZIG_GLOBAL_CACHE_DIR = ".zig-cache";
  ZIG_LOCAL_CACHE_DIR = ".zig-local-cache";

  shellHook = ''
    echo "sydradb dev shell with Zig $(zig version)" >&2
  '';
}
