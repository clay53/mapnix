{
  description = "A very basic flake";

  inputs = {
    oldNixpkgs.url = "github:NixOs/nixpkgs/23.11";
  };

  outputs = { self, oldNixpkgs }: rec {
    nixosModules.default = { config, lib, pkgs, ... }:
    let
      cfg = config.services.mapnix;
      openstreetmap-carto-python = pkgs.python3.withPackages (python-pkgs: [
        python-pkgs.pyyaml
        python-pkgs.requests
        python-pkgs.psycopg2-binary
      ]);
      openstreetmap-carto = 
        pkgs.stdenv.mkDerivation rec {
          pname = "openstreetmap-carto";
          version = "v5.9.0";

          src = cfg.openstreetmap-carto-src;

          buildPhase = ''
            cp -r $src .
            ${pkgs.gnused}/bin/sed 's/"gis"/"${cfg.user}"/g' ./project.mml > ./patched.mml
          '';

          installPhase = ''
            cp -r . $out
            ${oldNixpkgs.legacyPackages.x86_64-linux.carto}/bin/carto $out/patched.mml > $out/mapnik.xml
          '';
        };
    in
    {
      imports = [];

      options.services.mapnix = {
        enable = lib.mkEnableOption "Default setup for mapnix";
        user = lib.mkOption {
          type = lib.types.str;
          default = "gis";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "gis";
        };
        openstreetmap-carto-src = lib.mkOption {
          default = pkgs.fetchFromGitHub {
            owner = "gravitystorm";
            repo = "openstreetmap-carto";
            rev = "v5.9.0";
            hash = "sha256-zJ9e2lx2ChzdOhXRA3AhbMUPpDUJcYnCp27pRu2+Byc=";
          };
        };
        stylesFile = lib.mkOption {
          type = lib.types.str;
          default = "${openstreetmap-carto}/mapnik.xml";
        };
        externalDataDownloadCache = lib.mkOption {
          type = lib.types.str;
          default = "/var/cache/openstreetmap-carto-download";
        };
        renderd = {
          tileCacheDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/cache/renderd-tiles";
          };
          configFile = lib.mkOption {
            type = lib.types.str;
            default = "${pkgs.writers.writeText "renderd.conf" ''
              ; BASIC AND SIMPLE CONFIGURATION:

              [renderd]
              pid_file=/run/renderd/renderd.pid
              stats_file=/run/renderd/renderd.stats
              socketname=/run/renderd/renderd.sock
              num_threads=4
              tile_dir=${cfg.renderd.tileCacheDir}
              dbname=${cfg.user}
              
              [mapnik]
              plugins_dir=${pkgs.mapnik}/lib/mapnik/input
              font_dir=/run/current-system/sw/share/X11/fonts
              font_dir_recurse=true
              
              ; ADD YOUR LAYERS:

              [ajt]
              XML=${cfg.stylesFile}
              URI=/ajt/
              TILEDIR=${cfg.renderd.tileCacheDir}
              MAXZOOM=20
            ''}";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        users.groups.${cfg.group} = {};
        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
        };
        users.users.${config.services.httpd.user}.extraGroups = [ cfg.group ];
        services.postgresql = {
          enable = true;
          extensions = ps: [
            ps.postgis
          ];
          ensureUsers = [
            {
              name = cfg.user;
              ensureDBOwnership = true;
              ensureClauses.login = true;
            }
          ];
          ensureDatabases = [
            cfg.user
          ];
        };
        services.httpd = {
          enable = true;
          extraModules = [
            {
              name = "tile";
              path = "${pkgs.apacheHttpdPackages.mod_tile}/modules/mod_tile.so";
            }
          ];
          virtualHosts.mapnix = {
            extraConfig = ''
              LoadTileConfigFile ${cfg.renderd.configFile}
              ModTileRenderdSocketName /run/renderd/renderd.sock
              ModTileCacheDurationMinimum 10
              ModTileCacheDurationMax 10
              ModTileRequestTimeout 0
              ModTileMissingRequestTimeout 30
            '';
          };
        };
        systemd.tmpfiles.rules =
          map (dir: "d ${dir} 0750 ${cfg.user} ${cfg.group} - -") [
            "/run/renderd"
            "${cfg.renderd.tileCacheDir}"
            "${cfg.externalDataDownloadCache}"
          ];
        systemd.services.mapnix-db-setup = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            User = "postgres";
            Group = "postgres";
          };
          after = [ "postgresql.service" ];
          script = "${config.services.postgresql.package}/bin/psql -c 'CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS hstore;' ${cfg.user}";
        };
        systemd.services.mapnix-renderd = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            User = cfg.user;
            Group = cfg.group;
          };
          after = [ "mapnix-db-setup.service" ];
          preStart = "until ${config.services.postgresql.package}/bin/pg_isready -U postgres; do sleep 1; done";
          script = "${config.services.postgresql.package}/bin/psql -d ${cfg.user} -f ${openstreetmap-carto}/indexes.sql && ${config.services.postgresql.package}/bin/psql -d ${cfg.user} -f ${openstreetmap-carto}/functions.sql && PATH='${pkgs.gdal}/bin:$PATH' ${openstreetmap-carto-python}/bin/python3 ${openstreetmap-carto}/scripts/get-external-data.py -C -d ${cfg.user} -c ${openstreetmap-carto}/external-data.yml -D ${cfg.externalDataDownloadCache} && ${pkgs.apacheHttpdPackages.mod_tile}/bin/renderd -f -c ${cfg.renderd.configFile}";
        };
        fonts.fontDir.enable = true;
      };
    };
  };
}
