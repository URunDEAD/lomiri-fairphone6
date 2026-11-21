# x86_64 VM test of ./module.nix with the image's PipeWire/WirePlumber: a null sink stands
# in for the speaker; the sound reaching it is recorded from its monitor and measured.
#
#   nix-build feature-push/velrune/audio-roles/vm-test.nix
{ nixpkgs ? (import ../../../upstream/mobile-nixos/npins).nixpkgs
, pkgs ? import nixpkgs { system = "x86_64-linux"; }
}:
pkgs.testers.runNixOSTest {
  name = "velrune-audio-roles";
  nodes.machine = { pkgs, ... }: {
    imports = [ ./module.nix ];
    velrune.audio.roles = {
      enable = true;
      fixedSpeaker = { volume = 0.8; node = "fake-speaker"; route = null; };
    };
    services.pipewire = {
      enable = true;
      wireplumber.enable = true;
      extraConfig.pipewire."90-fake-speaker"."context.objects" = [{
        factory = "adapter";
        args = {
          "factory.name" = "support.null-audio-sink";
          "node.name" = "fake-speaker";
          "node.description" = "Fake speaker";
          "media.class" = "Audio/Sink";
          "audio.position" = "FL,FR";
          "priority.session" = 1000;
          "priority.driver" = 1000;
          "monitor.channel-volumes" = true;
        };
      }];
    };
    users.users.alice = { isNormalUser = true; uid = 1000; linger = true; };
    environment.systemPackages = [ pkgs.pipewire pkgs.wireplumber pkgs.python3
      # role-rec ROLE|- OUT: record the speaker's monitor while /tmp/tone.wav plays with ROLE.
      (pkgs.writeShellScriptBin "role-rec" ''
        role=$1 out=$2
        rm -f "$out"
        timeout -s INT 4 pw-record --format s16 --rate 48000 --channels 2 \
          -P '{ stream.capture.sink = true media.role = "Test" }' --target fake-speaker "$out" &
        rec=$!
        sleep 1
        case "$role" in
          -) pw-play /tmp/tone.wav & ;;
          target) pw-play --target fake-speaker /tmp/tone.wav & ;;
          *) pw-play --media-role="$role" /tmp/tone.wav & ;;
        esac
        play=$!
        sleep 0.7
        if [ -n "''${DEBUG:-}" ]; then pw-link -l; wpctl status; fi
        wait $play
        wait $rec || true
      '')
    ];
  };
  testScript = ''
    import json

    def as_alice(cmd):
        return machine.succeed(f"su alice -c 'export XDG_RUNTIME_DIR=/run/user/1000; {cmd}'")

    def nodes():
        return {o["info"]["props"].get("node.name"): o["id"]
                for o in json.loads(as_alice("pw-dump"))
                if o.get("type") == "PipeWire:Interface:Node" and o.get("info")}

    def level(role):
        """RMS (0..1) of what reaches the speaker while a tone plays with that role."""
        as_alice(f"role-rec {role or '-'} /tmp/rec.wav")
        status, out = machine.execute("python3 ${./measure.py} /tmp/rec.wav")
        print(f"level({role}): {out}")
        assert status == 0, out
        return float(out.strip().splitlines()[-1])

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    as_alice("pw-cli info 0 >/dev/null")
    machine.wait_until_succeeds("systemctl --user -M alice@ is-active wireplumber.service", timeout=60)
    machine.succeed("python3 ${./measure.py} --tone /tmp/tone.wav && chown alice /tmp/tone.wav")

    with subtest("three role sinks; the speaker stays the default sink"):
        for role in ["multimedia", "notification", "alarm"]:
            machine.wait_until_succeeds(
                f"su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 pw-dump' | grep -q input.loopback.sink.role.{role}", timeout=60)
        assert "fake-speaker" in as_alice("wpctl inspect @DEFAULT_AUDIO_SINK@")

    with subtest("the speaker is set to its fixed level when WirePlumber starts"):
        machine.wait_until_succeeds("systemctl --user -M alice@ is-active velrune-fixed-speaker.service", timeout=90)
        speaker = nodes()["fake-speaker"]
        assert "Volume: 0.80" in as_alice(f"wpctl get-volume {speaker}"), as_alice(f"wpctl get-volume {speaker}")

    with subtest("Media at 0: media is silent, Alarm, notifications and calls still play"):
        n = nodes()
        as_alice(f"wpctl set-volume {n['input.loopback.sink.role.multimedia']} 0")
        media, music, alarm, notification, phone = (
            level(None), level("Music"), level("Alarm"), level("Notification"), level("Phone"))
        print(f"levels: media {media} music {music} alarm {alarm} notification {notification} phone {phone}")
        assert media < 0.002 and music < 0.002, (media, music)
        assert alarm > 0.05 and notification > 0.05 and phone > 0.05, (alarm, notification, phone)
        # WirePlumber 0.5.15: a stream sent to an output by name (target.object, what the
        # Shell's remembered output per app uses) still goes to its role sink. Pinned here
        # so a WirePlumber change shows up; the Shell requirement covers it.
        targeted = level("target")
        print(f"explicit target with Media at 0: {targeted}")
        assert targeted < 0.002, targeted

    with subtest("the Alarm level is the alarm role sink's own"):
        as_alice(f"wpctl set-volume {nodes()['input.loopback.sink.role.alarm']} 0")
        assert level("Alarm") < 0.002
        as_alice(f"wpctl set-volume {nodes()['input.loopback.sink.role.alarm']} 1")
        as_alice(f"wpctl set-volume {nodes()['input.loopback.sink.role.multimedia']} 1")
        assert level(None) > 0.05
  '';
}
