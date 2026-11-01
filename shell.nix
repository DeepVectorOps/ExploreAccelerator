{ pkgs ? import <nixpkgs> {} }:
let
  hp = pkgs.haskellPackages;
in pkgs.mkShell {
  packages = [
    (import ./default.nix { inherit pkgs; })
    pkgs.ripgrep
    (hp.ghcWithPackages (p: [ p.aeson p.bytestring p.containers p.Diff p.directory p.filepath p.hspec p.process p.string-conversions p.text p.unix ]))
  ];
}
