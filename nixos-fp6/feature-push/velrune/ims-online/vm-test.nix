# x86_64 VM test of ./module.nix: the real watcher and recovery units against a fake oFono
# on the system bus, with stand-ins for fp6-ims-pdn (fails while offline, and a set number
# of early starts like CallFailed internal/211) and imsd. No modem, no phone.
#
#   nix-build feature-push/velrune/ims-online/vm-test.nix
{ nixpkgs ? (import ../../../upstream/mobile-nixos/npins).nixpkgs
, pkgs ? import nixpkgs { system = "x86_64-linux"; }
}:
let
  py = pkgs.python3.withPackages (ps: [ ps.dbus-python ps.pygobject3 ]);
in
pkgs.testers.runNixOSTest {
  name = "fp6-ims-online";
  nodes.machine = { pkgs, lib, ... }: {
    imports = [ ./module.nix ];
    services.dbus.packages = [
      (pkgs.writeTextDir "share/dbus-1/system.d/org.ofono.conf" ''
        <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
         "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
        <busconfig>
          <policy user="root"><allow own="org.ofono"/></policy>
          <policy context="default"><allow send_destination="org.ofono"/></policy>
        </busconfig>
      '')
    ];
    systemd.services.ofono = {
      description = "fake oFono";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "dbus"; BusName = "org.ofono"; ExecStart = "${py}/bin/python3 ${./fake-ofono.py}"; };
    };
    # fp6-ofono-online's job at boot: the modem comes up offline and is set online.
    systemd.services.fp6-ofono-online = {
      wantedBy = [ "ofono.service" ];
      after = [ "ofono.service" ];
      bindsTo = [ "ofono.service" ];
      path = [ pkgs.systemd ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "sleep 3; busctl call org.ofono /qrtrsoc_0 org.ofono.Modem SetProperty sv Online b true";
    };
    # Stand-in PDN: shaped like the real unit (Restart=on-failure 5 s, wanted by oFono);
    # fails its first N starts (/run/fake-pdn-fail), and exits 1 when the modem goes
    # offline, like fp6-ims-pdn on "IMS call state disconnected".
    systemd.services.fp6-ims-pdn = {
      after = [ "ofono.service" "fp6-ofono-online.service" ];
      bindsTo = [ "ofono.service" ];
      wantedBy = [ "ofono.service" ];
      path = [ pkgs.systemd pkgs.gnugrep pkgs.coreutils ];
      script = ''
        n=$(cat /run/fake-pdn-fail 2>/dev/null || echo 0)
        if [ "$n" -gt 0 ]; then echo $((n - 1)) > /run/fake-pdn-fail; echo "StartNetwork: CallFailed internal/211"; exit 1; fi
        online() { busctl call org.ofono /qrtrsoc_0 org.ofono.Modem GetProperties | grep -q '"Online" b true'; }
        online || { echo "modem offline"; exit 1; }
        echo "IMS PDN up"; systemd-notify --ready
        while online; do sleep 1; done
        echo "IMS call state 1 (disconnected); exiting for a restart"; exit 1
      '';
      # Type=notify like the real unit: `systemctl start` returns once the PDN is up.
      serviceConfig = { Type = "notify"; NotifyAccess = "all"; Restart = "on-failure"; RestartSec = "5s"; };
      startLimitIntervalSec = 600;
      startLimitBurst = 20;
    };
    systemd.services.imsd = {
      after = [ "fp6-ims-pdn.service" ];
      bindsTo = [ "fp6-ims-pdn.service" ];
      partOf = [ "fp6-ims-pdn.service" ];
      wantedBy = [ "fp6-ims-pdn.service" ];
      serviceConfig = { ExecStartPre = "${pkgs.coreutils}/bin/sleep 1"; ExecStart = "${pkgs.coreutils}/bin/sleep infinity"; };
    };
  };
  testScript = ''
    def online(v):
        machine.succeed(f"busctl call org.ofono /qrtrsoc_0 org.ofono.Modem SetProperty sv Online b {v}")

    def recover_runs():
        return int(machine.succeed("(journalctl -b -q -u fp6-ims-online-recover.service -g 'Starting' || true) | wc -l").strip())

    machine.wait_for_unit("multi-user.target")
    with subtest("boot: the chain comes up through oFono, the watcher does nothing"):
        machine.wait_until_succeeds("systemctl is-active imsd.service", timeout=60)
        machine.succeed("systemctl is-active fp6-ims-online-watch.service")
        machine.sleep(6)
        machine.fail("test -e /run/fp6-ims-online/stopped")
        assert recover_runs() == 0, "recovery ran at boot"

    with subtest("flight mode on: imsd, the PDN and fp6-ims-recover's retries stop, and stay stopped"):
        machine.succeed("systemd-run --on-active=600 --unit=fp6-ims-recover-retry-pdn true")
        online("false")
        machine.wait_until_succeeds("test -e /run/fp6-ims-online/stopped", timeout=30)
        machine.wait_until_fails("systemctl is-active fp6-ims-pdn.service", timeout=30)
        machine.fail("systemctl is-active imsd.service")
        machine.fail("systemctl is-active fp6-ims-recover-retry-pdn.timer")
        machine.sleep(15)
        machine.fail("systemctl is-active fp6-ims-pdn.service")
        machine.fail("systemctl is-failed fp6-ims-pdn.service")

    with subtest("flight mode off: PDN retried until up (two early failures), then imsd"):
        machine.succeed("echo 2 > /run/fake-pdn-fail")
        online("true")
        machine.wait_until_succeeds("systemctl is-active imsd.service", timeout=180)
        machine.succeed("systemctl is-active fp6-ims-pdn.service")
        # The first try fails (CallFailed); the PDN's own Restart= may win the next one.
        machine.wait_until_succeeds("journalctl -b -u fp6-ims-online-recover.service | grep -q 'imsd started'", timeout=60)
        machine.succeed("journalctl -b -u fp6-ims-online-recover.service | grep -q 'IMS PDN not up yet (try 1)'")
        machine.succeed("journalctl -b -u fp6-ims-online-recover.service | grep -q 'IMS PDN up after'")
        machine.fail("test -e /run/fp6-ims-online/stopped")

    with subtest("a restarted watcher still restores what it stopped"):
        online("false")
        machine.wait_until_succeeds("test -e /run/fp6-ims-online/stopped", timeout=30)
        machine.succeed("systemctl restart fp6-ims-online-watch.service")
        machine.sleep(2)
        online("true")
        machine.wait_until_succeeds("systemctl is-active imsd.service", timeout=120)

    with subtest("an offline blip shorter than the debounce changes nothing"):
        before = recover_runs()
        online("false")
        online("true")
        machine.sleep(10)
        machine.succeed("systemctl is-active imsd.service")
        assert recover_runs() == before, "a blip started a recovery"
  '';
}
