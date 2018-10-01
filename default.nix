let
  lib = { pkgs, ... }: pkgs.lib.makeExtensible (libSelf: {
    repos = {
      gargoyle = pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "gargoyle";
        rev = "2c19c569325ad76694526e9b688ccdbf148df980";
        sha256 = "0257p0qd8xx900ngghkjbmjnvn7pjv05g0jm5kkrm4p6alrlhfyl";
      };
      groundhog = pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "groundhog";
        rev = "febd6c12a676693b1d7339e54a4d107c4a67fcc3";
        sha256 = "1q05nrqdzh26r17wsd53sdj106dxh3qlg66pqr3jsi8d63iyaq8k";
      };
      bytestring-trie = pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "bytestring-trie";
        rev = "27117ef4f9f01f70904f6e8007d33785c4fe300b";
        sha256 = "103fqr710pddys3bqz4d17skgqmwiwrjksn2lbnc3w7s01kal98a";
      };
      # monoidal-containers = pkgs.fetchFromGitHub {
      #   owner = "obsidiansystems";
      #   repo = "monoidal-containers";
      #   rev = "e0302a475a4a22b74cbcbd9bfc5371cc3cd5a8f2";
      #   sha256 = "023rwfjs58v2sc9vrwg3s4960vywilsilkxghamvncb34288a0y2";
      # };
    };

    srcs = {
      constraints-extras = pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "constraints-extras";
        rev = "abd1bab0738463657fc6303e606015a97b01c8a0";
        sha256 = "0lpc3cy8a7h62zgqf214g5bf68dg8clwgh1fs8hada5af4ppxf0l";
      };

      # gargoyle = libSelf.repos.gargoyle + /gargoyle;
      # gargoyle-postgresql = libSelf.repos.gargoyle + /gargoyle-postgresql;

      groundhog = libSelf.repos.groundhog + /groundhog;
      groundhog-postgresql = libSelf.repos.groundhog + /groundhog-postgresql;
      groundhog-th = libSelf.repos.groundhog + /groundhog-th;

      # monoidal-containers = libSelf.repos.monoidal-containers;

      rhyolite-aeson-orphans = ./aeson-orphans;
      rhyolite-backend = ./backend;
      rhyolite-backend-db = ./backend-db;
      rhyolite-backend-db-gargoyle = ./backend-db-gargoyle;
      rhyolite-backend-snap = ./backend-snap;
      # rhyolite-common = ./common;
      rhyolite-datastructures = ./datastructures;
      rhyolite-frontend = ./frontend;

      websockets = pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "websockets";
        rev = "1493961d12c30c786b568df09d285582bc649fbc";
        sha256 = "17gf1xpj57gskigczxl7pk6n5iz6lbq3p8395755v1kfl37cdb5a";
      };
    };

    haskellOverrides = pkgs.lib.composeExtensions
      (self: super: pkgs.lib.mapAttrs (name: path: self.callCabal2nix name path {}) libSelf.srcs)
      (self: super: {
        monad-logger = if (self.ghc.isGhcjs or false) then null else super.monad-logger;
        rhyolite-common = self.callPackage ./common {};

        gargoyle = pkgs.haskell.lib.doJailbreak             (self.callCabal2nix "gargoyle" (libSelf.repos.gargoyle + /gargoyle) {});
        gargoyle-postgresql = pkgs.haskell.lib.doJailbreak  (self.callCabal2nix "gargoyle-postgresql" (libSelf.repos.gargoyle + /gargoyle-postgresql) {});
        gargoyle-nix = pkgs.haskell.lib.doJailbreak         (self.callCabal2nix "gargoyle-nix" (libSelf.repos.gargoyle + /gargoyle-nix) {});

        bytestring-trie = pkgs.haskell.lib.dontCheck (self.callCabal2nix "bytestring-trie" libSelf.repos.bytestring-trie {});

        gargoyle-postgresql-nix = pkgs.haskell.lib.doJailbreak (pkgs.haskell.lib.addBuildTools
          (self.callCabal2nix "gargoyle-postgresql-nix" (libSelf.repos.gargoyle + /gargoyle-postgresql-nix) {})
          [ pkgs.postgresql ]); # TH use of `staticWhich` for `psql` requires this on the PATH during build time.
        heist = pkgs.haskell.lib.doJailbreak super.heist;
        pipes-binary = pkgs.haskell.lib.doJailbreak super.pipes-binary;
      });
  });

  proj = { pkgs ? import <nixpkgs> {} }:
    let
      obeliskImpl = pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "obelisk";
        rev = "a9ef07b769a1c5dc30e981895df0d1ec7ca2ff0f";
        sha256 = "004j1ipnds68pmcydkf13nq5zhlw86g8rp4fi1syq0b6z45dv5wj";
      };
      reflex-platform = (import obeliskImpl {}).reflex-platform;
    in reflex-platform.project ({ pkgs, ... }@args: {
      packages = {
        # In an obelisk project, these will be added by `obelisk.project`.
        # Since this is not *actually* an obelisk project, we need to supply these manually.
        obelisk-asset-serve-snap = obeliskImpl + /lib/asset/serve-snap;
        obelisk-snap-extras = obeliskImpl + /lib/snap-extras;
      };
      overrides = (lib args).haskellOverrides;
      shells = rec {
        ghc = [
          "rhyolite-backend"
          "rhyolite-backend-db"
          "rhyolite-backend-db-gargoyle"
          "rhyolite-backend-snap"
        ] ++ ghcjs;
        ghcjs = [
          "rhyolite-aeson-orphans"
          "rhyolite-common"
          "rhyolite-datastructures"
          "rhyolite-frontend"
        ];
      };
      tools = ghc: [ pkgs.postgresql ];
    });
in {
  inherit proj lib;
}
