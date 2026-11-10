# Velrune session on the Fairphone 6: the Velrune compositor and Shell run
# directly on the panel (DRM/KMS, Adreno GLES through GBM) instead of Lomiri.
#
# Extends trial-lomiri-full-kernel6-fp6.nix through trial-velrune-session.nix.
# Kernel, initrd, DTB and every heavy package stay as they are; this module
# only adds units, /etc files and the Shell build the phone already holds.
#
#  * Boot reaches multi-user.target. Lomiri stays installed and its
#    display-manager unit stays loadable but nothing pulls it in at boot
#    (graphical.target is what wants display-manager.service).
#    The plan's headless-a.nix used display-manager.enable = false, which
#    renders the unit as a symlink to /dev/null (masked): Lomiri could then not
#    be started by hand. It is not used here.
#  * velrune-session.service: velrune-compositor --backend drm --ui-scale 1.5
#    as `user` on tty1 with PAMName=login, the shape of nixpkgs'
#    services/wayland/cage.nix and of the E2-lite run (2026-11-09). It conflicts
#    with display-manager.service, so starting either one stops the other.
#    Restart=on-failure with a start limit; past the limit OnFailure only logs
#    and leaves a marker. Nothing else depends on the session, so SSH,
#    NetBird, oFono, imsd and PipeWire keep running whatever it does.
#  * Power key: the Shell owns it (0.1.25 blanks and wakes the panel). logind
#    ignores a short press and reboots on a 5 s hold (into whatever boot_b pins); fp6-lomiri-powerd, which also
#    reads KEY_POWER and drives the backlight, now runs only with Lomiri.
#  * Shell and apps are packages in the system closure (velrune.session.shell and
#    velrune.session.apps), by default built from the git pins in ./apps.nix by
#    ./velrune-apps.nix (each repository's own aarch64 recipe; every source a commit
#    checked by the NAR hash of its tree; ./gen-apps-nix.py writes apps.nix from the
#    builds on the phone). No builtins.storePath. The apps are in
#    environment.systemPackages and services.dbus.packages, so their desktop entries,
#    share/velrune (ai-actions, plugins) and D-Bus session services come from
#    /run/current-system/sw, which the Shell reads as system trust (reserved ids such
#    as `settings` and over-lock calls need it). The Shell discovers desktop entries
#    itself: no --app-dir and no generated manifests any more.
#    The launcher exports SLINT_SCALE_FACTOR=1.5 and GRID_UNIT_PX=8 for the
#    compositor, the Shell and every app they start, and puts
#    /run/current-system/sw/share first in XDG_DATA_DIRS. The launcher, not
#    Environment=, sets them: pam_env (PAMName=login) would otherwise put back
#    Lomiri's GRID_UNIT_PX=24 from /etc/pam/environment.
#  * Headless parts from phone-os-plan.md section 3: VoLTE at boot (imsd with
#    AUDIO_USER, polkit rule for the radio group), linger for PipeWire, NetBird
#    without a graphical agent, packet data kept on, plymouth-quit at boot, and
#    the fp6.trial=1 revert timer for RAM boots.
#  * lomiri-kdeconnect builds without its tests: their PEM fixtures are gitignored.
#  * fp6-selftest skips its Lomiri-only checks while the Velrune session runs.
#  * Desktop speed-ups and live-test fixes: `user` is a trusted Nix user (direct
#    `nix copy --to ssh-ng://user@phone`); VELRUNE_APPLICATION_MAP for links;
#    Wi-Fi powersave forced off.
#
# Build/eval only. Never writes a boot image, slot or partition.
{ config, lib, pkgs, ... }:
let
  user = "user";
  uid = config.users.users.${user}.uid;
  home = config.users.users.${user}.home;

  cfg = config.velrune.session;
  # Built from ./apps.nix only when an option keeps its default.
  pinned = import ./velrune-apps.nix { };

  # The compositor sets logind's LockedHint while the lock screen is up (--lock-hint auto,
  # on for --backend drm; needs the logind session PAMName=login opens) and turns the
  # screen off and on with the power key itself.
  velruneShell = cfg.shell;
  systemShare = "/run/current-system/sw/share";
  # pam_faillock tally of the Shell's PIN lock (root-owned, persistent).
  faillockDir = "/var/lib/velrune-lock/faillock";
  lockCheck = pkgs.callPackage ./lock-check/package.nix { };
  # `faillock` for that folder: sudo velrune-faillock --user user [--reset]
  velruneFaillock = pkgs.writeShellScriptBin "velrune-faillock" ''
    exec ${config.security.pam.package}/bin/faillock --dir ${faillockDir} "$@"
  '';

  applicationMap = "${home}/.local/share/velrune/applications.json";

  sessionEnv = {
    SLINT_SCALE_FACTOR = "1.5";
    GRID_UNIT_PX = "8";
    VELRUNE_APPLICATION_MAP = applicationMap;
    XDG_CURRENT_DESKTOP = "Velrune";
    DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${toString uid}/bus";
  };

  # Runs after PAM has set the environment, so these values win. XDG_DATA_DIRS keeps
  # PAM's list (the user profile, for apps not yet in the system) behind the system's.
  launch = pkgs.writeShellScript "velrune-session-launch" ''
    export XDG_DATA_DIRS="${systemShare}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    exec ${lib.escapeShellArgs ([ "${pkgs.coreutils}/bin/env" ]
      ++ lib.mapAttrsToList (n: v: "${n}=${v}") sessionEnv
      ++ [ "${velruneShell}/bin/velrune-compositor" ] ++ cfg.compositorArgs
      ++ [ "--" ] ++ cfg.shellArgs)}
  '';
in
{
  options.velrune.session = {
    shell = lib.mkOption {
      type = lib.types.package;
      default = pinned.shell;
      defaultText = lib.literalExpression "(import ./velrune-apps.nix { }).shell";
      description = "The Velrune Shell build (velrune-compositor and velrune-shell, aarch64).";
    };
    compositorArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--backend" "drm" "--ui-scale" "1.5" "--remote-screenshots" "--remote-input" ];
      description = "velrune-compositor arguments before `--`.";
    };
    shellArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--no-catalog" ];
      description = "Shell arguments after `--`. Apps come from the desktop entries in XDG_DATA_DIRS.";
    };
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      # Files, Docviewer and Gallery each ship bin/velrune-docplugin-* and its
      # share/velrune/doc-plugins entry, and the builds differ; Files' copy wins, as in the
      # user-profile installer.
      default = builtins.attrValues (pinned.apps // { files = lib.hiPrio pinned.apps.files; });
      defaultText = lib.literalExpression "builtins.attrValues (import ./velrune-apps.nix { }).apps (Files at high priority)";
      description = ''
        Velrune app packages installed system-wide: desktop entries, share/velrune
        (ai-actions, plugins), D-Bus session services and launchers under
        /run/current-system/sw.
      '';
    };
  };

  config = {
  system.nixos.tags = [ "velrune-session" ];

  # ---- Lomiri off at boot, still startable by hand ----------------------------
  systemd.defaultUnit = lib.mkForce "multi-user.target";
  # boot-splash-fp6.nix leaves plymouth-quit to LightDM; nothing else would quit it.
  systemd.services.plymouth-quit.wantedBy = lib.mkForce [ "multi-user.target" ];

  # ---- Velrune session ----------------------------------------------------------
  systemd.services.velrune-session = {
    description = "Velrune Shell session on tty1";
    after = [
      "systemd-user-sessions.service"
      "plymouth-start.service"
      "plymouth-quit.service"
      "systemd-logind.service"
      "getty@tty1.service"
      "user@${toString uid}.service"
    ];
    wants = [ "dbus.socket" "systemd-logind.service" "plymouth-quit.service" "user@${toString uid}.service" ];
    wantedBy = [ "multi-user.target" ];
    # Starting either one stops the other (Conflicts= works both ways). The Shell
    # owns the power key and the panel; fp6-lomiri-powerd would act on KEY_POWER and
    # the backlight too, so it runs only with Lomiri (see below).
    conflicts = [ "getty@tty1.service" "display-manager.service" "fp6-lomiri-powerd.service" ];
    before = [ "display-manager.service" "fp6-lomiri-powerd.service" ];
    # Never restart the screen from switch-to-configuration.
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig = {
      ConditionPathExists = "/dev/tty1";
      # Bounded: at most 4 starts in 5 minutes, then the unit fails for good.
      StartLimitIntervalSec = 300;
      StartLimitBurst = 4;
      OnFailure = [ "velrune-session-failed.service" ];
    };
    # Read by pam_systemd when the session opens, so logind records Type=wayland.
    # /etc/pam/environment sets no XDG_SESSION_* variable, so Environment= is enough.
    environment = { XDG_SESSION_TYPE = "wayland"; XDG_SESSION_DESKTOP = "velrune"; };
    serviceConfig = {
      # Live, after switch-to-configuration test: the foreground VT was still Lomiri's
      # tty2, logind kept the new tty1 session inactive, and DRM refused the
      # compositor ("Failed to disable connectors ... Permission denied",
      # direct_session active=false). Bring tty1 to the foreground first, as root
      # ("+"), before PAM opens the session. At boot it is already tty1: a no-op.
      ExecStartPre = "+${pkgs.kbd}/bin/chvt 1";
      ExecStart = launch;
      User = user;
      PAMName = "login";
      Restart = "on-failure";
      RestartSec = "3s";
      # SIGTERM gives the compositor its orderly stop (E2-lite: clean in < 1 s).
      TimeoutStopSec = "15s";
      IgnoreSIGPIPE = "no";
      UtmpIdentifier = "tty1";
      UtmpMode = "user";
      TTYPath = "/dev/tty1";
      TTYReset = "yes";
      TTYVHangup = "yes";
      TTYVTDisallocate = "yes";
      StandardInput = "tty-fail";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "velrune-session";
    };
  };

  # Past the start limit: record it and stop. No UI is started and nothing is
  # stopped, so SSH, NetBird, oFono/imsd and PipeWire are untouched.
  systemd.services.velrune-session-failed = {
    description = "Velrune session failed past its start limit";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${pkgs.coreutils}/bin/touch /run/velrune-session.failed"
        "${pkgs.util-linux}/bin/logger -p user.err -t velrune-session \"velrune-session failed past its start limit. Remote access and VoLTE are untouched. Lomiri: sudo systemctl start display-manager. Retry: sudo systemctl reset-failed velrune-session, then sudo systemctl start velrune-session\""
      ];
    };
  };

  environment.sessionVariables.VELRUNE_APPLICATION_MAP = applicationMap;

  # ---- Shell PIN lock -----------------------------------------------------------------
  # The Shell's opt-in secure lock checks the user's password through PAM service
  # "velrune-lock": NixOS's default stack, pam_unix through the setuid unix_chkpwd helper
  # (the Shell runs as `user`). Without the service the secure lock can never open.
  # secure_lock stays off by default in the Shell, so nothing changes until enabled.
  #
  # A durable attempt limit, for this service only (login, sshd, sudo and su are unchanged):
  # pam_faillock preauth, then pam_unix ([success=1 default=bad]), then authfail
  # ([default=die]) and authsucc (sufficient), Shell-B's tested order. 10 failures lock for
  # 15 min. The tally lives in a root-owned folder that survives reboots. Not `silent`: the
  # Shell reads "The account is locked due to N failed logins" / "(N minutes left to
  # unlock)" (C locale) to show "Too many attempts. Try again in N min."
  # Show / reset by hand: sudo velrune-faillock --user user [--reset]
  # (= faillock --dir /var/lib/velrune-lock/faillock --user user --reset)
  #
  # The tally is only read and written by a process that may open the folder (measured,
  # linux-pam 1.7.2): called as `user` the stack stays correct but never counts. The
  # counting check is velrune-lock-check below, which runs this service as root.
  security.pam.services.velrune-lock = {
    rules.auth =
      let
        auth = config.security.pam.services.velrune-lock.rules.auth;
        faillock = mode: order: control: {
          inherit order control;
          modulePath = "${config.security.pam.package}/lib/security/pam_faillock.so";
          settings = { ${mode} = true; dir = faillockDir; deny = 10; unlock_time = 900; };
        };
      in
      {
        faillock-preauth = faillock "preauth" (auth.unix.order - 10) "required";
        unix.control = lib.mkForce "[success=1 default=bad]";
        faillock-authfail = faillock "authfail" (auth.unix.order + 10) "[default=die]";
        faillock-authsucc = faillock "authsucc" (auth.unix.order + 20) "sufficient";
      };
  };
  systemd.tmpfiles.settings."40-velrune-lock".${faillockDir}.d = { user = "root"; group = "root"; mode = "0700"; };

  # The privileged check, so the root-owned tally above counts (the compositor's own PAM
  # child runs as `user` and cannot open it). Socket-activated, one root process per
  # connection; protocol in ./lock-check/velrune-lock-check.c and reports/team-os.md.
  # Only the uid that owns the active seat0 session (>= 1000) is checked, as itself.
  systemd.sockets.velrune-lock-check = {
    description = "Velrune lock-screen PIN check socket";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "/run/velrune-lock/check.sock" ];
    socketConfig = {
      Accept = true;
      SocketUser = "root";
      SocketGroup = "users";
      SocketMode = "0660";
      DirectoryMode = "0755";
      # Attempts are serialized by the helper; this only bounds waiting processes.
      MaxConnections = 4;
    };
  };
  systemd.services."velrune-lock-check@" = {
    description = "Velrune lock-screen PIN check (PAM velrune-lock, root)";
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        "${lockCheck}/bin/velrune-lock-check"
        "--service" "velrune-lock"
        "--dir" faillockDir "--deny" "10" "--unlock-time" "900" "--fail-interval" "900"
        "--lock-file" "/var/lib/velrune-lock/attempt.lock" "--min-fail-ms" "2000"
      ];
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      StateDirectory = "velrune-lock";
      StateDirectoryMode = "0700";
      RuntimeMaxSec = 60;
      UMask = "0077";
      # Root for /etc/shadow (owner read) and the tally; no capabilities at all.
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      IPAddressDeny = "any";
      RestrictAddressFamilies = [ "AF_UNIX" ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      # pam_faillock fchown()s a new tally file to the user; denied, it stays root's.
      SystemCallErrorNumber = "EPERM";
    };
  };

  # ---- Velrune apps, system-wide ----------------------------------------------------
  environment.systemPackages = cfg.apps ++ [ velruneFaillock ];
  # share/velrune: ai-actions (Chat's action discovery), doc-plugins, account-plugins.
  environment.pathsToLink = [ "/share/velrune" ];
  # Session-bus activation files (org.velrune.*.service) go into the bus configuration,
  # so dbus-broker starts the system copies; no per-user links are needed.
  services.dbus.packages = cfg.apps;
  # Services the user bus starts run under the user manager, not the session: give it the
  # system share too, ahead of whatever the user's own environment.d files add.
  environment.etc."environment.d/40-velrune-system.conf".text = ''
    XDG_DATA_DIRS=${systemShare}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
  '';

  # ---- Power key -----------------------------------------------------------------
  # Short press: the Shell (0.1.25) turns the screen off and on itself, so logind
  # must ignore it (the base config already does; forced here). A 5 s hold reboots,
  # unlike a poweroff still reachable over the network, and the Shell has no power
  # menu yet. The reboot boots whatever boot_b pins: the Lomiri generation until
  # boot_b is written with this one (plan step 8), this generation afterwards. The PMIC's own
  # hardware reset on a much longer hold is unaffected.
  services.logind.settings.Login = {
    HandlePowerKey = lib.mkForce "ignore";
    HandlePowerKeyLongPress = lib.mkForce "reboot";
  };
  # fp6-lomiri-powerd (Lomiri's display backend) reads KEY_POWER and drives the
  # backlight. Not at boot any more: display-manager pulls it in, and starting
  # velrune-session stops it (Conflicts= above).
  systemd.services.fp6-lomiri-powerd.wantedBy = lib.mkForce [ ];
  # Its unit changes here; a restart during switch-to-configuration would race the
  # session's start (Conflicts=) and could leave neither shell on the panel.
  systemd.services.fp6-lomiri-powerd.restartIfChanged = false;
  systemd.services.display-manager.wants = [ "fp6-lomiri-powerd.service" ];

  # ---- Self-test in the Velrune session -------------------------------------------
  # fp6-selftest-system (2 min after boot) failed its base "display-manager" check:
  # Lomiri is deliberately not running. The patch skips the Lomiri-only checks
  # (display-manager, lomiri, maliit) while velrune-session.service is active.
  hardware.fairphone6.selftest.package = lib.mkForce
    ((import ../selftest/default.nix { inherit pkgs; }).overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./selftest-velrune-session.patch ];
    }));

  # ---- Build fix for a clean checkout -------------------------------------------
  # lomiri-kdeconnect's unit test include_bytes!() two PEM fixtures that the repo's
  # .gitignore (*.pem) keeps out of git, so it cannot compile from a checkout. The
  # phone's build had them on disk. Skip the tests; the package itself is unchanged.
  hardware.fairphone6.kdeconnect.package = lib.mkForce
    ((pkgs.callPackage ../kdeconnect/package.nix { }).overrideAttrs (_: { doCheck = false; }));

  # ---- PipeWire and VoLTE without Lomiri (plan section 3) --------------------
  # PipeWire is a user service; linger starts the user manager at boot, before
  # (and independently of) the Velrune session.
  users.users.${user}.linger = true;
  services.fp6Ims.autoStart = true;
  # fp6-ims-pdn exits 1 on purpose when the IMS call drops or rmnet_ims vanishes
  # ("exiting for a restart", seen once during activation) and relies on systemd.
  # Restart=on-failure was already set; the delay was 30 s. Its preStart waits for the
  # PS attach (up to 300 s), so a quick restart never spins. imsd Requires= it and is
  # restarted with it. The start limit is generous so a flapping modem cannot leave
  # VoLTE dead until reset-failed.
  systemd.services.fp6-ims-pdn.serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = lib.mkForce "5s";
  };
  systemd.services.fp6-ims-pdn.startLimitIntervalSec = lib.mkForce 600;
  systemd.services.fp6-ims-pdn.startLimitBurst = lib.mkForce 20;

  # imsd must only ever run against a fresh PDN. Live, after `switch-to-configuration
  # test`: fp6-ims-pdn was "active" but imsd looped on "bring-up FAILED: no 401 to
  # unprotected REGISTER"; stopping imsd, restarting the PDN, waiting 6 s and starting
  # imsd fixed it. So:
  #  * BindsTo + After: a stop or restart of the PDN takes imsd down and (PartOf) brings it
  #    back after the PDN is up again, never in parallel with it;
  #  * ExecStartPre settles 6 s before every imsd start, so the new IMS link, route and
  #    /run/imsd.env are in place (the manual fix's wait);
  #  * three failed bring-ups in 10 minutes (20 s apart) end in OnFailure, which restarts
  #    the PDN and then imsd (fp6-ims-recover). Bounded: 6 recoveries per hour, then imsd
  #    stays failed and the journal says so; a person decides.
  systemd.services.imsd = {
    bindsTo = [ "fp6-ims-pdn.service" ];
    onFailure = [ "fp6-ims-recover.service" ];
    startLimitIntervalSec = lib.mkForce 600;
    startLimitBurst = lib.mkForce 3;
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 6";
      RestartSec = lib.mkForce "20s";
    };
  };
  systemd.services.fp6-ims-recover = {
    description = "Restart the IMS PDN and imsd after repeated failed IMS registrations";
    startLimitIntervalSec = 3600;
    startLimitBurst = 6;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "fp6-ims-recover" ''
        export PATH=${lib.makeBinPath [ pkgs.systemd pkgs.util-linux ]}
        logger -p user.warning -t fp6-ims-recover "imsd failed repeatedly: restarting fp6-ims-pdn, then imsd"
        systemctl reset-failed imsd.service
        systemctl restart fp6-ims-pdn.service || logger -p user.warning -t fp6-ims-recover "fp6-ims-pdn restart reported failure; starting imsd anyway"
        systemctl start imsd.service
      '';
    };
  };
  # Without it imsd looks up seat0's session for call audio.
  systemd.services.imsd.environment.AUDIO_USER = user;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("net.catcrafts.IMS1.") == 0 && subject.isInGroup("radio")) {
        return polkit.Result.YES;
      }
    });
  '';

  # ---- Remote access and data without a graphical agent ----------------------
  # fp6-vpn-restore (a graphical-session agent) was NetBird's only reconnect path.
  services.netbird.clients.netbird.autoStart = lib.mkForce true;
  # lomiri-indicator-network owned the mobile-data policy.
  systemd.services.fp6-ofono-data-on = {
    description = "FP6: keep oFono packet data enabled (no Lomiri policy owner)";
    wantedBy = [ "ofono.service" ];
    after = [ "fp6-ofono-online.service" ];
    bindsTo = [ "ofono.service" ];
    path = [ pkgs.systemd pkgs.gnugrep pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      m=$(busctl --system call org.ofono / org.ofono.Manager GetModems | grep -o '"/qrtrsoc_[0-9]*"' | head -1 | tr -d '"')
      [ -n "$m" ] || exit 0
      for i in $(seq 1 30); do
        busctl --system call org.ofono "$m" org.ofono.ConnectionManager SetProperty sv Powered b true && exit 0
        sleep 2
      done
      echo "ConnectionManager did not accept Powered"; exit 0
    '';
  };
  # Network stays up with the screen off or locked. Checked on the evaluated config
  # (OS2, 2026-11-09), nothing here turns Wi-Fi or data off or suspends:
  #  * systemd.sleep AllowSuspend/Hibernation/Hybrid/SuspendThenHibernate = "no"
  #    (fp6SuspendPolicy mode "guarded"), logind IdleAction "ignore", Suspend/Hibernate
  #    keys and the short power key "ignore", CanSuspend "na";
  #  * Wi-Fi powersave off (forced below), no rfkill/airplane unit or udev rule;
  #  * the Shell's screen off is a DRM blank in the compositor, and its system_sleep
  #    module only takes a logind delay inhibitor for PrepareForSleep; it never calls
  #    Suspend;
  #  * the Lomiri-session suspects (Stage.qml SIGSTOP of background/kept-ready apps,
  #    netpolicy's empty foreground on the lock screen) belong to
  #    graphical-session.target, which this session never starts. fp6-netpolicy-helper
  #    runs but acts only on calls from the user daemon, which is not running.
  # Powersave is already off (hardware-fp6.nix); force it so a later module cannot
  # turn it back on.
  networking.networkmanager.wifi.powersave = lib.mkForce false;
  # IPv6 on the Orng router black-holes: fixed in that NetworkManager profile
  # on the phone (ipv6.method disabled), not here.

  # ---- Desktop to phone copies --------------------------------------------------
  # `nix copy --to ssh-ng://user@<phone>` without root or signatures.
  # This is root-equivalent: a trusted user can import unsigned paths and pass
  # privileged settings to the daemon. sudo needs a password, so this turns "root
  # with the password" into "root without it" for every process running as `user`
  # (the Shell's apps included). Acceptable on this wipeable test phone only:
  # remove it before the phone holds anything that matters.
  nix.settings.trusted-users = lib.mkAfter [ user ];

  # ---- RAM boots only: an image with fp6.trial=1 is never written to boot_b --
  systemd.timers.fp6-trial-revert = {
    wantedBy = [ "timers.target" ];
    unitConfig.ConditionKernelCommandLine = "fp6.trial=1";
    timerConfig = { OnBootSec = "15min"; AccuracySec = "10s"; };
  };
  systemd.services.fp6-trial-revert = {
    description = "Unconfirmed trial boot: reboot back into the installed boot_b";
    unitConfig.ConditionKernelCommandLine = "fp6.trial=1";
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.systemd}/bin/systemctl --force reboot"; };
  };
  };
}
