#!/usr/bin/env python3
"""Small regression tests for playback capture command validation."""
import unittest
from pathlib import Path

from video_capture import safe_name


class CaptureNameTests(unittest.TestCase):
    def test_accepts_simple_matroska_names(self):
        self.assertEqual(safe_name('scene-01.mkv'), 'scene-01.mkv')
        self.assertEqual(safe_name('snap_20261023'), 'snap_20261023')

    def test_rejects_paths_and_shell_metacharacters(self):
        for name in ('../escape.mkv', 'a b.mkv', '$(touch x)', '', 'x'*97):
            with self.subTest(name=name), self.assertRaises(ValueError):
                safe_name(name)

    def test_recording_pipeline_is_separate_and_uses_bounded_latest_queue(self):
        source = Path(__file__).with_name('video_capture.py').read_text()
        player = Path(__file__).with_name('display_lz77_video.py').read_text()
        self.assertIn("self.Gst.parse_launch(description)", source)
        self.assertIn("self._record_appsrc = None", source)
        self.assertIn("record_source.emit('end-of-stream')", source)
        self.assertIn("max-buffers=3 leaky-type=downstream", source)
        self.assertNotIn('consume_recording_eos', player)


if __name__ == '__main__':
    unittest.main(verbosity=2)
