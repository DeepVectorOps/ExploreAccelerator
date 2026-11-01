{ pkgs ? import <nixpkgs> {} }:
let
  hp = pkgs.haskellPackages;
  # Claims shell out to rg, so it must be on PATH for the test suite (run as
  # part of the build) and at runtime.
  pkg = pkgs.haskell.lib.overrideCabal (hp.callCabal2nix "explore-accelerator" ./. {}) (old: {
    testToolDepends = (old.testToolDepends or []) ++ [ pkgs.ripgrep ];
  });
in pkgs.haskell.lib.justStaticExecutables pkg
