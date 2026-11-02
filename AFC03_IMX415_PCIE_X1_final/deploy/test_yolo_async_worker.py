#!/usr/bin/env python3
"""Exercise worker ownership/callbacks with real NumPy and a fake RKNN runtime."""
import sys
import types
import unittest
from unittest.mock import patch

import numpy as np

import yolo_reference
from rknn_yolo_backend import YoloWorker
from yolo_async_overlay import LatestBoxes


class AsyncWorkerTests(unittest.TestCase):
    def exercise(self, callback_failure=False, sync_display=False):
        errors, stats = [], []
        outputs = [np.zeros((1, 3, 7, n, n), np.float32) for n in (80, 40, 20)]
        outputs[0][0, 0, :4, 40, 40] = 0.5
        outputs[0][0, 0, 4, 40, 40] = 0.9
        outputs[0][0, 0, 5, 40, 40] = 0.8
        owner = self
        class Buffer:
            pts = 123_000_000
            mapped = False
            def map(self, _flags):
                self.mapped = True
                return True, types.SimpleNamespace(data=bytes(1920 * 1080 * 3))
            def unmap(self, _mapped):
                self.mapped = False
        buffer = Buffer()
        structure = types.SimpleNamespace(get_value=lambda key: {
            'width':1920,'height':1080,'format':'RGB'}[key])
        sample = types.SimpleNamespace(
            get_caps=lambda: types.SimpleNamespace(get_structure=lambda _: structure),
            get_buffer=lambda: buffer)
        class Sink:
            calls = 0
            def emit(self, *_):
                self.calls += 1
                if self.calls != 1:
                    raise AssertionError('Worker failed to stop after its callback')
                return sample
        class Runtime:
            NPU_CORE_0 = 1
            released = False
            def load_rknn(self, _path):
                return 0
            def init_runtime(self, **_kwargs):
                return 0
            def inference(self, inputs):
                owner.assertFalse(buffer.mapped, 'DMA buffer held across NPU inference')
                owner.assertEqual(inputs[0].shape, (1,640,640,3))
                owner.assertEqual(inputs[0].dtype, np.uint8)
                owner.assertTrue(inputs[0].flags.c_contiguous)
                np.testing.assert_array_equal(inputs[0][0,0,0], [33,22,11])
                return outputs
            def release(self):
                self.released = True
        runtime = Runtime()
        api = types.ModuleType('rknnlite.api')
        api.RKNNLite = types.SimpleNamespace(NPU_CORE_0=1)
        class RuntimeFactory:
            NPU_CORE_0 = 1
            def __new__(cls):
                return runtime
        api.RKNNLite = RuntimeFactory
        package = types.ModuleType('rknnlite')
        package.__path__ = []
        cv2 = types.ModuleType('cv2')
        cv2.COLOR_RGB2BGR = 0
        cv2.FONT_HERSHEY_SIMPLEX = 0
        cv2.LINE_AA = 16
        cv2.cvtColor = lambda small, _: small[..., ::-1].copy()
        drawn_labels = []
        cv2.rectangle = lambda *_args: None
        cv2.getTextSize = lambda *_args: ((40, 12), 2)
        cv2.putText = lambda _image, label, *_args: drawn_labels.append(label)
        small = np.empty((640,640,3), np.uint8)
        small[:] = (11,22,33)
        store = LatestBoxes()
        def result(boxes, scores, classes, names, source_pts, acquired, sequence):
            self.assertFalse(buffer.mapped)
            self.assertEqual(names, ('person','car'))
            self.assertEqual(source_pts, buffer.pts)
            if callback_failure:
                raise RuntimeError('publish failed')
            self.assertTrue(store.publish(boxes, scores, classes, names, source_pts, acquired, sequence))
            worker.stop.set()
        displayed = []
        def display(frame, sequence):
            self.assertEqual(frame.shape, (1080, 1920, 3))
            self.assertEqual(sequence, 1)
            displayed.append(frame)
            worker.stop.set()
        Gst = types.SimpleNamespace(MSECOND=1_000_000, MapFlags=types.SimpleNamespace(READ=1))
        worker = YoloWorker('fixture.rknn', Sink(), Gst, lambda *x: stats.append(x),
                            errors.append, on_frame=display if sync_display else None,
                            on_result=None if sync_display else result, max_fps=0)
        with patch.dict(sys.modules, {'cv2':cv2,'rknnlite':package,'rknnlite.api':api}), \
             patch.object(yolo_reference, 'letterbox', return_value=(small,1/3,0,140)):
            worker.run()
        self.assertFalse(buffer.mapped)
        self.assertTrue(runtime.released)
        if sync_display:
            self.assertEqual(errors, [])
            self.assertEqual(len(displayed), 1)
            self.assertEqual(drawn_labels, ['person 0.72'])
            self.assertEqual(store.counts(), (0, 0))
        elif callback_failure:
            self.assertEqual(errors, ['publish failed'])
            self.assertEqual(stats, [])
        else:
            self.assertEqual(errors, [])
            self.assertEqual(len(stats), 1)
            snapshot = store.for_frame(buffer.pts)[0]
            self.assertEqual(snapshot.sequence, 1)
            self.assertEqual(snapshot.entries[0][1], 'person 0.72')

    def test_result_published_after_unmap_with_original_pts_and_labels(self):
        self.exercise()

    def test_callback_failure_propagates_and_releases_runtime(self):
        self.exercise(callback_failure=True)

    def test_sync_display_publishes_the_inferred_frame_and_box_before_push(self):
        self.exercise(sync_display=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
