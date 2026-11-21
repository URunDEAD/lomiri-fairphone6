# VoLTE after flight mode (lomiri-fairphone6 rev5n), imported by ../velrune-session.nix and
# by ./vm-test.nix (the same units against a fake oFono).
{ pkgs, ... }:
let
  imsOnline = pkgs.callPackage ./package.nix { };
in
{
  system.build.fp6-ims-online = imsOnline;

  # Settings' airplane mode and the Shell's flight toggle set oFono Modem.Online=false,
  # which ends the IMS PDN; fp6-ims-pdn and imsd only start with oFono at boot, so VoLTE
  # stayed down after flight mode until a hand recovery. fp6-ims-online-watch follows
  # Online (./fp6_ims_online.py): offline for 4 s -> stop
  # fp6-ims-online-recover, fp6-ims-recover's runs and retries (an oFono restart would
  # set the modem online and undo flight mode), imsd and the PDN; back online -> start
  # fp6-ims-online-recover, which waits for registration and PS attach, then every 10 s
  # `reset-failed fp6-ims-pdn imsd; start fp6-ims-pdn` until the PDN is up (1-2 min),
  # then starts imsd; past 10 min it hands over to fp6-ims-recover@pdn. It only undoes
  # its own stop (boot and oFono restarts are left to the boot units and
  # fp6-ims-recover@ in ../velrune-session.nix), at most 10 times
  # an hour (and the unit's start limit, 12). Never msm-modem-uim-selection. fp6-ims-recover
  # does nothing while the modem is offline (its own guard), so it cannot undo flight mode.
  # The watcher may restart on activation (it keeps its state in /run/fp6-ims-online and
  # starts nothing by itself); the recovery never starts from activation.
  systemd.services.fp6-ims-online-watch = {
    description = "VoLTE follows the modem's Online state (flight mode)";
    wantedBy = [ "multi-user.target" ];
    after = [ "dbus.service" "ofono.service" ];
    serviceConfig = {
      ExecStart = "${imsOnline}/bin/fp6-ims-online watch";
      Restart = "always";
      RestartSec = "10s";
      RuntimeDirectory = "fp6-ims-online";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      Environment = [ "STATE_DIR=/run/fp6-ims-online" ];
    };
  };
  systemd.services.fp6-ims-online-recover = {
    description = "Bring VoLTE back after the modem came back online";
    after = [ "ofono.service" ];
    restartIfChanged = false;
    startLimitIntervalSec = 3600;
    startLimitBurst = 12;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${imsOnline}/bin/fp6-ims-online recover";
      TimeoutStartSec = "20min";
    };
  };
}
