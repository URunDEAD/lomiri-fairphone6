# Role-based audio for the Velrune session (Clock RG-05): WirePlumber 0.5's role-based
# linking policy with one loopback sink per role, imported by ../velrune-session.nix and
# by ./vm-test.nix.
#
#   stream media.role                       -> role sink (node name)                  -> speaker
#   Music Movie Game Multimedia, or none    -> input.loopback.sink.role.multimedia     (Media)
#   Notification Event                      -> input.loopback.sink.role.notification   (Ring & notifications)
#   Alarm                                   -> input.loopback.sink.role.alarm          (Alarm)
#   Phone (imsd, Phone's call streams), and every other role -> the default sink, as before
#
# Each role sink's own volume is that role's level. The ducking WirePlumber does (a higher
# role over a lower one) acts on the loopbacks' output streams (output.loopback.sink.role.*)
# and resets them to 1.0, never on the role sinks, so a level set on a role sink stays.
# WirePlumber does not remember virtual sinks' volumes: whoever sets a role level (the
# Shell's org.velrune.Audio1) keeps it and sets it again when the role sink appears.
#
# Known effects (./vm-test.nix measures them, WirePlumber 0.5.15):
#  * an explicit target (target.object, the Shell's remembered output per app) does not
#    take a stream out of its role: it still goes to its role sink and from there to the
#    default output;
#  * a sink-monitor capture without a media.role gets the default role too and records the
#    Media role sink, not the speaker: give monitor captures a role no loopback takes.
#
# fixedSpeaker.volume (default null: off): set the built-in speaker to one level when
# WirePlumber starts, and only while its speaker route is active. Turn it on together
# with a Shell whose Media slider is the Multimedia role sink's volume (Shell requirement
# in System's vault/Plan/System 1.0 Acceptance.md, "Role-based audio"); with a Shell that
# still sets the speaker's own volume it would reset Media at every boot.
{ config, lib, pkgs, ... }:
let
  cfg = config.velrune.audio.roles;
  fixedSpeaker = pkgs.callPackage ./package.nix { };
  # The fragment is SPA-JSON written out as WirePlumber's own files are (bare words in
  # `requires`), not services.pipewire.wireplumber.extraConfig: WirePlumber 0.5.15 keeps the
  # quotes of JSON strings in a component's `requires` array ("no component provides
  # '\"loopback.sink.role.multimedia\"'") and then does not start at all, which would take
  # every sound and the call audio with it. ./vm-test.nix caught both that and the missing
  # adapter factory (the loopbacks need pw.node-factory.adapter in WirePlumber's context).
  role = { id, description, roles, priority, lower }: ''
      {
        name = libpipewire-module-loopback, type = pw-module
        arguments = {
          node.name = "loopback.sink.role.${id}"
          node.description = "${description}"
          audio.position = [ FL FR ]
          capture.props = {
            node.name = "input.loopback.sink.role.${id}"
            media.class = "Audio/Sink"
            node.virtual = true
            # Never the default sink: the hardware outputs rank above.
            priority.session = 0
            priority.driver = 0
            policy.role-based.target = true
            device.intended-roles = [ ${lib.concatMapStringsSep " " (r: "\"${r}\"") roles} ]
            policy.role-based.priority = ${toString priority}
            policy.role-based.action.same-priority = "mix"
            policy.role-based.action.lower-priority = "${lower}"
          }
          playback.props = {
            node.name = "output.loopback.sink.role.${id}"
            node.passive = true
            # Not a role any loopback takes, so the default role below cannot send a
            # loopback's output into a loopback: it goes to the default sink.
            media.role = "Loopback"
          }
        }
        provides = loopback.sink.role.${id}
        requires = [ pw.node-factory.adapter ]
      }
  '';
  roleList = [
    { id = "multimedia"; description = "Media"; roles = [ "Music" "Movie" "Game" "Multimedia" ]; priority = 10; lower = "mix"; }
    { id = "notification"; description = "Ring and notifications"; roles = [ "Notification" "Event" ]; priority = 20; lower = "duck"; }
    { id = "alarm"; description = "Alarm"; roles = [ "Alarm" ]; priority = 30; lower = "duck"; }
  ];
  fragment = pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/60-velrune-audio-roles.conf" ''
    # Velrune role-based audio (lomiri-fairphone6 feature-push/velrune/audio-roles/module.nix)
    wireplumber.profiles = {
      main = {
        policy.linking.role-based.loopbacks = required
      }
    }
    wireplumber.settings = {
      # Streams without a role are Media.
      node.stream.default-media-role = "Multimedia"
      linking.role-based.duck-level = 0.3
    }
    wireplumber.components = [
      {
        type = virtual, provides = policy.linking.role-based.loopbacks
        requires = [ ${lib.concatMapStringsSep " " (r: "loopback.sink.role.${r.id}") roleList} ]
      }
    ${lib.concatMapStrings role roleList}]
  '';
in
{
  options.velrune.audio.roles = {
    enable = lib.mkEnableOption "role-based audio: Multimedia, Notification and Alarm role sinks";
    fixedSpeaker = {
      volume = lib.mkOption {
        type = lib.types.nullOr (lib.types.numbers.between 0 1.5);
        default = null;
        description = "Level the built-in speaker is set to when WirePlumber starts; null leaves it alone.";
      };
      node = lib.mkOption {
        type = lib.types.str;
        default = "alsa_output.platform-sound*";
        description = "Glob for the speaker sink's node.name.";
      };
      route = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "*Speaker*";
        description = "Glob the active output route must match (name and description); null: no route check.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.pipewire.wireplumber.configPackages = [ fragment ];
    system.build.velrune-audio-roles-conf = fragment;
    system.build.velrune-fixed-speaker = fixedSpeaker;
    systemd.user.services.velrune-fixed-speaker = lib.mkIf (cfg.fixedSpeaker.volume != null) {
      description = "Built-in speaker at its fixed level (role-based audio)";
      after = [ "wireplumber.service" ];
      partOf = [ "wireplumber.service" ];
      wantedBy = [ "wireplumber.service" ];
      serviceConfig = {
        Type = "oneshot";
        # Active once the level has held for 3 s (checkable: systemctl --user is-active).
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs ([ "${fixedSpeaker}/bin/velrune-fixed-speaker"
          (toString cfg.fixedSpeaker.volume) cfg.fixedSpeaker.node ]
          ++ lib.optional (cfg.fixedSpeaker.route != null) cfg.fixedSpeaker.route);
      };
    };
  };
}
