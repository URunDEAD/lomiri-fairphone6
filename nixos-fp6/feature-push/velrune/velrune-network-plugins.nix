# Velrune network connection-type plugins (technical-roadmap.md §3, "VPN and
# connection-type plugins").
#
#   velrune.network.plugins = [ "wireguard" "openvpn" ];
#
# For each id this installs
#   - the NetworkManager VPN plugin, through networking.networkmanager.plugins,
#     when the type needs one (WireGuard is native to NetworkManager: none), and
#   - the Velrune manifest <id>.json into share/velrune/network-plugins, copied
#     from the catalog the Settings package ships (velrune.network.catalog).
#
# Removing an id removes both: /etc/NetworkManager/VPN/<plugin>.name, the
# plugin's D-Bus and systemd files and the manifest are all generated from this
# list, so nothing is left behind. system.checks fails the build if the
# installed manifest set is not exactly the list (for example because some
# package ships its own share/velrune/network-plugins).
#
# Contract with Settings: Settings ships every plugin it knows as
# share/settings/network-plugins/<id>.json in its own package (what is
# *available*). Only this module writes share/velrune/network-plugins (what is
# *installed*), so Settings must not ship files there itself.
{ config, lib, pkgs, ... }:
let
  cfg = config.velrune.network;

  # Built without the GNOME editor (libnma, GTK): Settings renders the editor.
  # nixpkgs keeps glib only in nativeBuildInputs; with GNOME it arrives through
  # gtk3/libnma, without it configure finds no glib-2.0 (seen with openvpn).
  noGnome = p: (p.override { withGnome = false; }).overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.glib ];
  });

  settings = lib.findFirst
    (p: (p.pname or "") == "velrune-settings-device")
    null
    (config.velrune.session.apps or [ ]);

  unknown = lib.filter (id: !(cfg.pluginPackages ? ${id})) cfg.plugins;

  ids = lib.unique cfg.plugins;

  nmPlugins = lib.filter (p: p != null)
    (map (id: cfg.pluginPackages.${id} or null) ids);

  manifests = pkgs.runCommand "velrune-network-plugins" { } ''
    dst=$out/share/velrune/network-plugins
    mkdir -p "$dst"
    ${lib.concatMapStrings (id: ''
      src=${lib.escapeShellArg "${cfg.catalog}/${id}.json"}
      if [ ! -f "$src" ]; then
        echo "velrune.network.plugins: no manifest for '${id}' at $src" >&2
        exit 1
      fi
      cp "$src" "$dst/${id}.json"
    '') ids}
  '';

  # The installed set must be exactly the list: no stray or stale manifest.
  check = pkgs.runCommand "velrune-network-plugins-check" { } ''
    have=$(ls ${config.system.path}/share/velrune/network-plugins 2>/dev/null | sort | tr '\n' ' ')
    want=${lib.escapeShellArg (lib.concatMapStrings (id: "${id}.json ") (lib.sort lib.lessThan ids))}
    if [ "$have" != "$want" ]; then
      echo "share/velrune/network-plugins is '$have', expected '$want'" >&2
      exit 1
    fi
    touch $out
  '';
in
{
  options.velrune.network = {
    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "wireguard" ];
      example = [ "wireguard" "openvpn" ];
      description = ''
        Network connection-type plugins to install. Each id needs an entry in
        velrune.network.pluginPackages and a manifest <id>.json in
        velrune.network.catalog.
      '';
    };

    pluginPackages = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.package);
      default = { };
      description = ''
        The NetworkManager plugin package for each known plugin id, or null
        when NetworkManager supports the type natively. Add an entry here to
        make a new id available; the built-in ones are always present.
      '';
    };

    catalog = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        if settings == null then null
        else "${settings}/share/settings/network-plugins";
      defaultText = lib.literalExpression
        ''"''${settings}/share/settings/network-plugins"'';
      description = ''
        Directory holding <id>.json manifests, by default the catalog the
        pinned Settings app ships.
      '';
    };
  };

  config = lib.mkMerge [
    {
      velrune.network.pluginPackages = lib.mapAttrs (_: lib.mkDefault) {
        wireguard = null; # native in NetworkManager; kernel module wireguard
        openvpn = noGnome pkgs.networkmanager-openvpn;
        openconnect = noGnome pkgs.networkmanager-openconnect;
        vpnc = noGnome pkgs.networkmanager-vpnc;
        l2tp = noGnome pkgs.networkmanager-l2tp;
        fortisslvpn = noGnome pkgs.networkmanager-fortisslvpn;
        sstp = noGnome pkgs.networkmanager-sstp;
        strongswan = pkgs.networkmanager-strongswan;
      };
    }

    (lib.mkIf (cfg.plugins != [ ]) {
      assertions = [
        {
          assertion = unknown == [ ];
          message = "velrune.network.plugins: unknown id(s) ${lib.concatStringsSep ", " unknown}; known: ${lib.concatStringsSep ", " (lib.attrNames cfg.pluginPackages)}";
        }
        {
          assertion = cfg.catalog != null;
          message = "velrune.network.plugins needs velrune.network.catalog (no Settings app in velrune.session.apps)";
        }
      ];

      networking.networkmanager.plugins = nmPlugins;
      environment.systemPackages = [ manifests ];
      environment.pathsToLink = [ "/share/velrune" ];
      system.checks = [ check ];
    })
  ];
}
