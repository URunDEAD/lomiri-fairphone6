"""Tests for fixed_speaker.pick on pw-dump-shaped objects (no PipeWire)."""
import unittest

import fixed_speaker as m


def node(i, name, cls="Audio/Sink", device=None, index=None):
    props = {"node.name": name, "media.class": cls}
    if device is not None:
        props.update({"device.id": device, "card.profile.device": index})
    return {"id": i, "type": "PipeWire:Interface:Node", "info": {"props": props}}


def card(i, routes):
    return {"id": i, "type": "PipeWire:Interface:Device", "info": {"params": {"Route": routes}}}


SPEAKER = {"index": 1, "direction": "Output", "device": 3, "name": "[Out] Speaker", "description": "Speaker"}
EARPIECE = {"index": 2, "direction": "Output", "device": 3, "name": "[Out] Earpiece", "description": "Earpiece"}
MIC = {"index": 0, "direction": "Input", "device": 4, "name": "[In] Mic1", "description": "Mic"}
NODE = "alsa_output.platform-sound.HiFi__Speaker__sink"


class PickTests(unittest.TestCase):
    def test_speaker_route_active(self):
        objs = [card(50, [SPEAKER, MIC]), node(60, NODE, device=50, index=3)]
        self.assertEqual([i for i, _ in m.pick(objs, "alsa_output.platform-sound*", "*Speaker*")], [60])

    def test_earpiece_route_is_left_alone(self):
        objs = [card(50, [EARPIECE, MIC]), node(60, NODE, device=50, index=3)]
        self.assertEqual(m.pick(objs, "alsa_output.platform-sound*", "*Speaker*"), [])

    def test_role_sinks_streams_and_other_cards_are_left_alone(self):
        objs = [card(50, [SPEAKER]),
                node(60, "input.loopback.sink.role.multimedia"),
                node(61, NODE, cls="Stream/Output/Audio", device=50, index=3),
                node(62, "bluez_output.AA_BB", device=50, index=3)]
        self.assertEqual(m.pick(objs, "alsa_output.platform-sound*", "*Speaker*"), [])

    def test_without_a_route_check(self):
        objs = [node(70, "fake-speaker"), node(71, "other")]
        self.assertEqual([i for i, _ in m.pick(objs, "fake-speaker")], [70])

    def test_removed_objects(self):
        self.assertEqual(m.pick([{"id": 3, "type": "PipeWire:Interface:Node", "info": None}], "*"), [])


if __name__ == "__main__":
    unittest.main()
