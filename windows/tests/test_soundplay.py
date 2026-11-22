import sys
import unittest

from claudenotch import sounds

from claudenotch_win import soundplay


class SoundPlayTests(unittest.TestCase):
    def test_names_cannot_leave_the_media_folder(self):
        self.assertIsNone(soundplay.path("..\\..\\evil"))
        self.assertIsNone(soundplay.path("a/b"))
        self.assertIsNone(soundplay.path("C:evil"))
        self.assertIsNone(soundplay.path(""))
        self.assertFalse(soundplay.play(None))
        self.assertFalse(soundplay.play("No Such Sound"))

    def test_every_mac_sound_ships_with_the_app(self):
        self.assertEqual(soundplay.available(sounds.CHOICES), list(sounds.CHOICES))
        names = [d for _, _, _, d in sounds.EVENTS if d] + [d for *_, d in sounds.CATEGORIES]
        self.assertEqual(soundplay.available(names), names)

    def test_the_users_own_copy_wins(self):
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d, mock.patch.object(soundplay, "user_dir", lambda: d):
            mine = os.path.join(d, "Funk.wav")
            open(mine, "wb").close()
            self.assertEqual(soundplay.path("Funk"), mine)
            self.assertNotEqual(soundplay.path("Pop"), None)


def _aiff(channels=2, bits=24, rate=48000, frames=4, aifc=None):
    import struct
    width = (bits + 7) // 8
    ext = bytes.fromhex("400EBB80000000000000") if rate == 48000 else bytes.fromhex("400EAC44000000000000")
    comm = struct.pack(">hIh", channels, frames, bits) + ext + (aifc or b"")
    samples = bytes((i * 7) & 0xFF for i in range(frames * channels * width))
    ssnd = struct.pack(">II", 0, 0) + samples
    body = (b"AIFC" if aifc else b"AIFF") + b"COMM" + struct.pack(">I", len(comm)) + comm + (b"\x00" if len(comm) & 1 else b"")         + b"SSND" + struct.pack(">I", len(ssnd)) + ssnd
    return b"FORM" + struct.pack(">I", len(body)) + body, samples


class AiffTests(unittest.TestCase):
    def test_reads_the_macs_format(self):
        from claudenotch_win import aiffwav
        data, samples = _aiff()
        ch, bits, rate, raw, little = aiffwav.read(data)
        self.assertEqual((ch, bits, rate, raw, little), (2, 24, 48000, samples, False))
        wav = aiffwav.to_wav(data)
        import io
        import wave
        with wave.open(io.BytesIO(wav)) as w:
            self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (2, 2, 48000, 4))
            first = w.readframes(1)[:2]
        self.assertEqual(first, bytes([samples[1], samples[0]]))   # top 16 bits, now little-endian
        _, _, rate, _, little = aiffwav.read(_aiff(1, 16, 44100, 3, aifc=b"sowt")[0])
        self.assertEqual((rate, little), (44100, True))

    def test_rejects_what_it_cannot_play(self):
        from claudenotch_win import aiffwav
        for bad in (b"", b"RIFF0000WAVE", _aiff(aifc=b"ima4")[0]):
            with self.assertRaises(ValueError):
                aiffwav.to_wav(bad)

    def test_a_users_aiff_is_played_as_wav(self):
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d, mock.patch.object(soundplay, "user_dir", lambda: d):
            with open(os.path.join(d, "Glass.aiff"), "wb") as f:
                f.write(_aiff()[0])
            p = soundplay.path("Glass")
            self.assertTrue(p.endswith(os.path.join(".converted", "Glass.wav")))
            with open(p, "rb") as f:
                self.assertEqual(f.read(4), b"RIFF")
            with open(os.path.join(d, "Hero.aiff"), "wb") as f:
                f.write(b"junk")
            self.assertNotIn(".converted", soundplay.path("Hero") or "")   # falls back to the built-in Hero


if __name__ == "__main__":
    unittest.main()
