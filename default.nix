{ sources ? import ./nix/sources.nix }:
let
  pkgs = import sources.nixpkgs { config = { allowBroken = true; }; };
  hp = pkgs.haskellPackages;
  pkg = pkgs.haskell.lib.overrideCabal (hp.callCabal2nix "explore-accelerator" ./. {}) (old: {
    testToolDepends = (old.testToolDepends or []) ++ [ pkgs.ripgrep ];
  });
in pkgs.haskell.lib.justStaticExecutables pkg
