"""vm-test.nix helper: `measure.py --tone OUT` writes a 2 s 440 Hz stereo tone (WAV,
48 kHz, s16, half scale); `measure.py IN` prints the RMS (0..1) of a WAV file's second
half-second onwards, so the recorder's start-up silence does not count."""
import math
import struct
import sys
import wave

RATE = 48000

if sys.argv[1] == "--tone":
    with wave.open(sys.argv[2], "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for i in range(RATE * 2):
            v = int(16383 * math.sin(2 * math.pi * 440 * i / RATE))
            frames += struct.pack("<hh", v, v)
        w.writeframes(bytes(frames))
    sys.exit(0)

# pw-record is stopped by a signal, so the header's sizes may be unfinished: take the
# samples after the "data" chunk header (the recorder writes s16 stereo, vm-test.nix).
raw = open(sys.argv[1], "rb").read()
at = raw.find(b"data")
data = raw[at + 8:] if at >= 0 else b""
data = data[: len(data) // 4 * 4]
samples = struct.unpack(f"<{len(data) // 2}h", data)
samples = samples[2 * RATE // 2:]
rms = math.sqrt(sum((x / 32768.0) ** 2 for x in samples) / max(1, len(samples)))
print(f"{rms:.5f}")
sys.stderr.write(f"{len(raw)} bytes, {len(samples)} samples after 0.5 s\n")
