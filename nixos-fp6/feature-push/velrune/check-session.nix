# Evaluation checks of the Velrune session image (System 1.0 IM-01). Build/eval only:
#
#   nix-instantiate --eval --strict --json --option max-jobs 1 -E "import ./feature-push/velrune/check-session.nix { }"
#
# Prints the facts and stops with an error if one is wrong. It never builds or activates.
{ nixpkgs ? (import ../../upstream/mobile-nixos/npins).nixpkgs }:
let
  trial = import ./trial-velrune-session.nix { inherit nixpkgs; };
  config = trial.config;
  lib = trial.pkgs.lib;
  pinned = import ./velrune-apps.nix { };
  user = config.velrune.session.user;
  systemPackages = map (p: p.outPath) config.environment.systemPackages;
  fontNames = map (p: p.pname or p.name or "") config.fonts.packages;
  udev = config.services.udev.extraRules;
  facts = {
    toplevel = config.system.build.toplevel.outPath;
    shell = { inherit (pinned.inventory.shell) version out from; inSession = config.velrune.session.shell.outPath == pinned.inventory.shell.out; };
    settings = { inherit (pinned.inventory.settings) version out from; systemTrust = builtins.elem pinned.inventory.settings.out systemPackages; };
    system = { inherit (import ./system-pin.nix) rev; };
    chargeLimit = {
      enable = config.programs.velrune.session.chargeLimit.enable;
      userInGroup = builtins.elem "velrune-power" config.users.users.${user}.extraGroups;
      udevRule = lib.hasInfix ''LABEL="velrune_charge_limit_end"'' udev
        && lib.hasInfix "charge_control_end_threshold" udev;
    };
    monochromeEmoji = {
      font = builtins.elem "noto-fonts-monochrome-emoji" fontNames;
      firstEmojiFamily = builtins.head config.fonts.fontconfig.defaultFonts.emoji;
    };
    applicationMap = config.environment.sessionVariables.VELRUNE_APPLICATION_MAP;
    velruneSessionStillTheFp6Unit = !config.programs.velrune.session.enable
      && config.systemd.services.velrune-session.restartIfChanged == false;
    modemUnitsNotRestarted = lib.all (u: config.systemd.services.${u}.restartIfChanged == false)
      [ "ofono" "fp6-ims-pdn" "imsd" "msm-modem-uim-selection" "fp6-ofono-online" "fp6-ofono-data-on" "rmtfs" ];
    # VoLTE after flight mode (rev5n): the watcher runs at boot, the recovery only on its
    # request (never from activation or a target), and neither names the UIM selection.
    imsOnline =
      let
        watch = config.systemd.services.fp6-ims-online-watch;
        recover = config.systemd.services.fp6-ims-online-recover;
      in {
        watcherAtBoot = builtins.elem "multi-user.target" watch.wantedBy
          && lib.hasSuffix "/bin/fp6-ims-online watch" watch.serviceConfig.ExecStart
          && watch.serviceConfig.Restart == "always";
        recoverOnDemand = recover.wantedBy == [ ] && recover.requiredBy == [ ]
          && recover.restartIfChanged == false
          && lib.hasSuffix "/bin/fp6-ims-online recover" recover.serviceConfig.ExecStart
          && recover.startLimitBurst == 12;
        uimUntouched = !(lib.hasInfix "msm-modem-uim" (builtins.toJSON [ watch.serviceConfig recover.serviceConfig ]));
      };
    # Role-based audio (rev5n): imported and off; switched on, it adds the WirePlumber
    # fragment and the fixed-speaker user unit and leaves call audio (role Phone) alone.
    audioRoles =
      let
        on = (trial.eval.extendModules { modules = [ {
          velrune.audio.roles = { enable = lib.mkForce true; fixedSpeaker.volume = 1.0; };
        } ]; }).config;
        # The fragment's text from the derivation (no aarch64 build during evaluation).
        conf = on.system.build.velrune-audio-roles-conf.text;
      in {
        offInThisImage = !config.velrune.audio.roles.enable
          && !(config.systemd.user.services ? velrune-fixed-speaker);
        whenOn = builtins.elem on.system.build.velrune-audio-roles-conf on.services.pipewire.wireplumber.configPackages
          && on.systemd.user.services ? velrune-fixed-speaker
          && lib.hasInfix "input.loopback.sink.role.alarm" conf
          && lib.hasInfix "node.stream.default-media-role = \"Multimedia\"" conf
          && !(lib.hasInfix "\"Phone\"" conf);
      };
  };
  ok = facts.shell.inSession && facts.shell.version == "0.1.193"
    && facts.settings.systemTrust && lib.versionAtLeast facts.settings.version "0.1.21"
    && facts.chargeLimit.enable && facts.chargeLimit.userInGroup && facts.chargeLimit.udevRule
    && facts.monochromeEmoji.font && facts.monochromeEmoji.firstEmojiFamily == "Noto Emoji"
    && lib.hasPrefix "/nix/store/" facts.applicationMap
    && lib.hasSuffix "/packaging/applications.json" facts.applicationMap
    && facts.velruneSessionStillTheFp6Unit && facts.modemUnitsNotRestarted
    && facts.imsOnline.watcherAtBoot && facts.imsOnline.recoverOnDemand && facts.imsOnline.uimUntouched
    && facts.audioRoles.offInThisImage && facts.audioRoles.whenOn;
in
if ok then facts else throw "check-session.nix: ${builtins.toJSON facts}"
