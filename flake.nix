{
  description = "A very basic flake";

  outputs = { self }: rec {
    nixosModules.default = { config, lib, pkgs, ... }:
    let
      cfg = config.services.mapnix;
      openstreetmap-carto = pkgs.stdenv.mkDerivation rec {
        pname = "openstreetmap-carto";
        version = "v5.9.0";

        src = pkgs.fetchFromGitHub {
          owner = "gravitystorm";
          repo = "openstreetmap-carto";
          rev = version;
          hash = "sha256-zJ9e2lx2ChzdOhXRA3AhbMUPpDUJcYnCp27pRu2+Byc=";
        };

        installPhase = ''
          mkdir -p $out/styles
          ${pkgs.carto}/bin/carto $src/project.mml > $out/styles/mapnik.xml
        '';
      };
    in
    {
      imports = [];

      options.services.mapnix = {
        enable = lib.mkEnableOption "Default setup for mapnix";
        user = lib.mkOption {
          type = lib.types.str;
          default = "mapnix";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "mapnix";
        };
        stylesFile = lib.mkOption {
          type = lib.types.str;
          default = "${openstreetmap-carto}/styles/mapnik.xml";
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
              
              [mapnik]
              plugins_dir=/usr/lib/mapnik/3.1/input
              font_dir=/usr/share/fonts/truetype
              font_dir_recurse=true
              
              ; ADD YOUR LAYERS:

              [ajt]
              XML=${cfg.stylesFile}
              URI=/ajt/
            ''}";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        users.groups.${cfg.group} = {};
        users.users.mapnix = {
          isSystemUser = true;
          group = cfg.group;
        };
        services.postgresql = {
          enable = true;
          extensions = ps: [
            ps.postgis
          ];
          ensureUsers = [
            {
              name = cfg.user;
              ensureDBOwnership = true;
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
              ModTileRequestTimeout 0
              ModTileMissingRequestTimeout 30
            '';
          };
        };
        systemd.tmpfiles.rules =
          map (dir: "d ${dir} 0750 ${cfg.user} ${cfg.group} - -") [
            "/run/renderd"
            "${cfg.renderd.tileCacheDir}"
          ];
        systemd.services.mapnix-renderd = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            User = cfg.user;
            Group = cfg.group;
          };
          script = "${pkgs.apacheHttpdPackages.mod_tile}/bin/renderd -c ${cfg.renderd.configFile}";
        };
      };
    };
  };
}
