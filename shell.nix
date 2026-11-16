let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs { config = { allowBroken = true; }; };
  hp = pkgs.haskellPackages;
in pkgs.mkShell {
  packages = [
    (import ./default.nix { })
    pkgs.ripgrep
    (hp.ghcWithPackages (p: [
      p.aeson p.bytestring p.containers p.Diff p.directory p.filepath
      p.hspec p.lucid p.process p.scotty p.string-conversions p.text
      p.time p.transformers p.unix p.warp p.http-types p.file-embed
    ]))
  ];
}
