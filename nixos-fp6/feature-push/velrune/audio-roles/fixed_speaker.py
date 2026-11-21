"""velrune-fixed-speaker: put the built-in speaker at one fixed level.

With role-based audio (./module.nix) the levels people change are the role sinks'
(input.loopback.sink.role.multimedia for Media, .notification, .alarm); the hardware
speaker under them stays at one level, so an Alarm-role sound plays at its own level
whatever Media is. WirePlumber restores the speaker route's last volume, so this sets it
once when WirePlumber starts (velrune-fixed-speaker.service, a user unit).

  velrune-fixed-speaker VOLUME NODE_GLOB [ROUTE_GLOB]

Only Audio/Sink nodes whose node.name matches NODE_GLOB, and, with ROUTE_GLOB, only while
their card's active output route (pw-dump Route param of the node's device and
card.profile.device) matches it: the earpiece or headphones are never touched.
"""
import fnmatch
import json
import subprocess
import sys
import time


def pick(objects, node_glob, route_glob=None):
    """The node ids to set: [(id, why)]."""
    devices = {o["id"]: o for o in objects if o.get("type") == "PipeWire:Interface:Device"}
    out = []
    for o in objects:
        if o.get("type") != "PipeWire:Interface:Node":
            continue
        props = ((o.get("info") or {}).get("props")) or {}
        if props.get("media.class") != "Audio/Sink":
            continue
        if not fnmatch.fnmatchcase(str(props.get("node.name", "")), node_glob):
            continue
        if route_glob is None:
            out.append((o["id"], "no route check"))
            continue
        device = devices.get(props.get("device.id"))
        routes = (((device or {}).get("info") or {}).get("params") or {}).get("Route") or []
        index = props.get("card.profile.device")
        active = [r for r in routes if r.get("direction") == "Output" and r.get("device") == index]
        names = [str(r.get("name", "")) + " " + str(r.get("description", "")) for r in active]
        if any(fnmatch.fnmatchcase(n, route_glob) for n in names):
            out.append((o["id"], f"route {names[0].strip()}"))
    return out


def get_volume(node):
    """wpctl's "Volume: 0.80" for a node, or None."""
    try:
        out = subprocess.run(["wpctl", "get-volume", str(node)], capture_output=True,
                             text=True, timeout=20).stdout
        return float(out.split()[1])
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    volume = round(max(0.0, min(1.5, float(argv[1]))), 2)
    node_glob = argv[2]
    route_glob = argv[3] if len(argv) == 4 else None
    # WirePlumber finishes a node (route restore, default volume) after it appears and can
    # overwrite an early setting: set, then check until the level has held 3 s in a row.
    held = 0
    for _ in range(60):
        try:
            dump = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=20).stdout
            objects = json.loads(dump or "[]")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            objects = []
        targets = pick(objects, node_glob, route_glob)
        if targets:
            ok = True
            for node, why in targets:
                current = get_volume(node)
                if current is None or abs(current - volume) > 0.005:
                    ok = False
                    subprocess.run(["wpctl", "set-volume", str(node), f"{volume:.2f}"], timeout=20)
                    print(f"node {node} ({why}) was {current}, set to {volume:.2f}", flush=True)
            held = held + 1 if ok else 0
            if held >= 3:
                return 0
        else:
            held = 0
        time.sleep(1)
    print(f"sink {node_glob} (route {route_glob}) not at {volume:.2f} after 60 s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
