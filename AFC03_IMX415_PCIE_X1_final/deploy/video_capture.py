"""On-demand screenshot and H.264 recording controls for live playback."""
from datetime import datetime
import os
from pathlib import Path
import queue
import re
import socket
import threading
import time


def safe_name(value):
    basename = Path(value).name
    if basename != value or not re.fullmatch(r'[A-Za-z0-9_.-]{1,96}', basename):
        raise ValueError('capture filename may contain only letters, digits, dot, dash and underscore')
    return basename


class VideoCaptureManager:
    """A one-frame snapshot tap plus an optional leaky, dynamic encode branch."""

    def __init__(self, pipeline, Gst, GLib, control_path, output_dir,
                 encoder=None, logger=print):
        self.pipeline, self.Gst, self.GLib = pipeline, Gst, GLib
        self.control_path = Path(control_path)
        self.output_dir = Path(output_dir)
        self.encoder = encoder
        self.logger = logger
        self.tee = pipeline.get_by_name('decoded')
        self.appsink = pipeline.get_by_name('capture_tap')
        if self.tee is None or self.appsink is None:
            raise RuntimeError('Capture tee/appsink is missing from the playback graph')
        self._socket = None
        self._control_thread = None
        self._snapshot_thread = None
        self._snapshot_queue = queue.Queue(maxsize=1)
        self._snapshot_pending = threading.Event()
        self._lock = threading.Lock()
        self._closed = False
        self._record_filesink = None
        self._record_eos = None
        self._record_pipeline = None
        self._record_appsrc = None
        self._record_finish_thread = None
        self._record_path = None
        self._encoder_name = None
        self.appsink.connect('new-sample', self._on_sample)

    def start(self):
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.control_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.control_path.unlink()
        except FileNotFoundError:
            pass
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self._socket.settimeout(0.2)
        self._socket.bind(str(self.control_path))
        os.chmod(self.control_path, 0o600)
        self._snapshot_thread = threading.Thread(target=self._snapshot_worker,
                                                name='video-snapshot-writer', daemon=True)
        self._snapshot_thread.start()
        self._control_thread = threading.Thread(target=self._control_worker,
                                                name='video-capture-control', daemon=True)
        self._control_thread.start()
        self.logger(f'CAPTURE_CONTROL socket={self.control_path} dir={self.output_dir}')

    def _on_sample(self, sink):
        sample = sink.emit('pull-sample')
        if sample is None:
            return self.Gst.FlowReturn.ERROR
        caps = sample.get_caps()
        if caps is not None:
            self._capture_caps = caps.to_string()
        with self._lock:
            record_source = self._record_appsrc
        if record_source is not None:
            try:
                status = record_source.emit('push-buffer', sample.get_buffer())
                if status not in (self.Gst.FlowReturn.OK, self.Gst.FlowReturn.FLUSHING,
                                  self.Gst.FlowReturn.EOS):
                    self.logger(f'RECORDING_PUSH_WARNING status={status}')
            except Exception as exc:
                self.logger(f'RECORDING_PUSH_WARNING {exc}')
        if self._snapshot_pending.is_set():
            try:
                self._snapshot_queue.put_nowait(sample)
                self._snapshot_pending.clear()
            except queue.Full:
                pass
        return self.Gst.FlowReturn.OK

    def _control_worker(self):
        while not self._closed:
            try:
                data = self._socket.recv(256)
            except socket.timeout:
                continue
            except OSError:
                return
            command = data.decode('utf-8', errors='replace').strip()
            if command:
                self.GLib.idle_add(self._handle_command, command)

    def _handle_command(self, command):
        try:
            fields = command.split()
            action = fields[0]
            if action == 'snapshot' and len(fields) == 1:
                self._request_snapshot()
            elif action == 'record-start' and len(fields) <= 2:
                self._start_record(fields[1] if len(fields) == 2 else None)
            elif action == 'record-stop' and len(fields) == 1:
                self._stop_record()
            elif action == 'status' and len(fields) == 1:
                state = str(self._record_path) if self._record_path else 'idle'
                self.logger('CAPTURE_STATUS recording=' + state)
            else:
                raise ValueError('commands: snapshot | record-start [name.mkv] | record-stop | status')
        except Exception as exc:
            self.logger(f'CAPTURE_ERROR command={command!r} error={exc}')
        return False

    def _request_snapshot(self):
        if self._snapshot_pending.is_set():
            raise RuntimeError('a snapshot request is already pending')
        self._snapshot_pending.set()
        self.logger('SNAPSHOT requested (next decoded frame)')

    def _snapshot_worker(self):
        while True:
            try:
                sample = self._snapshot_queue.get(timeout=0.2)
            except queue.Empty:
                if self._closed:
                    return
                continue
            try:
                stamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
                path = self.output_dir / f'snapshot_{stamp}.jpg'
                caps = sample.get_caps().to_string()
                description = (f'appsrc name=still is-live=false format=time block=true '
                               f'caps="{caps}" ! videoconvert ! jpegenc quality=92 '
                               f'! filesink location="{path}"')
                pipeline = self.Gst.parse_launch(description)
                source = pipeline.get_by_name('still')
                if pipeline.set_state(self.Gst.State.PLAYING) == self.Gst.StateChangeReturn.FAILURE:
                    raise RuntimeError('could not start JPEG snapshot encoder')
                buffer = sample.get_buffer().copy()
                result = source.emit('push-buffer', buffer)
                if result != self.Gst.FlowReturn.OK:
                    raise RuntimeError(f'snapshot push failed: {result}')
                source.emit('end-of-stream')
                message = pipeline.get_bus().timed_pop_filtered(
                    10 * self.Gst.SECOND,
                    self.Gst.MessageType.EOS | self.Gst.MessageType.ERROR)
                if message is None:
                    raise RuntimeError('JPEG snapshot encoder timed out')
                if message.type == self.Gst.MessageType.ERROR:
                    error, detail = message.parse_error()
                    raise RuntimeError(f'{error}: {detail}')
                pipeline.set_state(self.Gst.State.NULL)
                self.logger(f'SNAPSHOT saved={path}')
            except Exception as exc:
                self.logger(f'SNAPSHOT_ERROR {exc}')
            finally:
                self._snapshot_queue.task_done()

    def _choose_encoder(self):
        candidates = [self.encoder] if self.encoder else ['mpph264enc', 'v4l2h264enc']
        for name in candidates:
            if name and self.Gst.ElementFactory.find(name) is not None:
                return name
        raise RuntimeError('No hardware H.264 encoder found (tried mpph264enc, v4l2h264enc)')

    def _start_record(self, requested_name):
        if self._record_pipeline is not None or self._record_finish_thread is not None:
            raise RuntimeError(f'recording already active: {self._record_path}')
        if not getattr(self, '_capture_caps', None):
            raise RuntimeError('waiting for the first decoded frame before recording')
        encoder = self._choose_encoder()
        if requested_name:
            filename = safe_name(requested_name)
            if not filename.lower().endswith('.mkv'):
                filename += '.mkv'
        else:
            filename = 'recording_' + datetime.now().strftime('%Y%m%d_%H%M%S') + '.mkv'
        path = self.output_dir / filename
        if path.exists():
            raise FileExistsError(path)
        description = (
            'appsrc name=record_source is-live=true format=time do-timestamp=false '
            'block=false max-buffers=3 leaky-type=downstream caps=' +
            '"' + self._capture_caps + '" ! '
            'queue max-size-buffers=3 max-size-bytes=0 max-size-time=0 leaky=downstream '
            '! videoconvert ! video/x-raw,format=NV12 ! ' + encoder +
            ' ! h264parse ! matroskamux ! filesink name=record_file location="' + str(path) + '"')
        record_pipeline = self.Gst.parse_launch(description)
        record_source = record_pipeline.get_by_name('record_source')
        filesink = record_pipeline.get_by_name('record_file')
        if record_source is None or filesink is None:
            record_pipeline.set_state(self.Gst.State.NULL)
            raise RuntimeError('record pipeline is missing appsrc/filesink')
        if record_pipeline.set_state(self.Gst.State.PLAYING) == self.Gst.StateChangeReturn.FAILURE:
            record_pipeline.set_state(self.Gst.State.NULL)
            raise RuntimeError('could not start the independent recording pipeline')
        self._record_pipeline = record_pipeline
        self._record_appsrc = record_source
        self._record_path, self._encoder_name = path, encoder
        self._record_eos = threading.Event()
        self._record_filesink = filesink
        self.logger(f'RECORDING started={path} encoder={encoder} pipeline=independent queue=3 leaky=downstream')

    def _stop_record(self):
        if self._record_pipeline is None:
            raise RuntimeError('recording is not active')
        path = self._record_path
        record_pipeline = self._record_pipeline
        record_source = self._record_appsrc
        with self._lock:
            self._record_appsrc = None
        record_source.emit('end-of-stream')
        self._record_pipeline = None
        self._record_filesink = None
        self._record_eos = None
        self._record_path = self._encoder_name = None
        self._record_finish_thread = threading.Thread(
            target=self._finish_record_pipeline, args=(record_pipeline, path),
            name='video-record-finalize', daemon=True)
        self._record_finish_thread.start()
        self.logger(f'RECORDING stopping={path}; playback continues')

    def _finish_record_pipeline(self, record_pipeline, path):
        try:
            message = record_pipeline.get_bus().timed_pop_filtered(
                5 * self.Gst.SECOND,
                self.Gst.MessageType.EOS | self.Gst.MessageType.ERROR)
            if message is None:
                self.logger(f'RECORDING_FINALIZE_WARNING timeout path={path}')
            elif message.type == self.Gst.MessageType.ERROR:
                error, detail = message.parse_error()
                self.logger(f'RECORDING_FINALIZE_ERROR path={path} error={error} detail={detail}')
            else:
                self.logger(f'RECORDING saved={path}')
        finally:
            record_pipeline.set_state(self.Gst.State.NULL)
            self._record_finish_thread = None

    def close(self):
        if self._record_pipeline is not None:
            try:
                self._stop_record()
            except Exception as exc:
                self.logger(f'RECORDING_STOP_ERROR {exc}')
        if self._record_finish_thread is not None:
            self._record_finish_thread.join(timeout=6.0)
        self._closed = True
        self._snapshot_pending.clear()
        if self._socket is not None:
            self._socket.close()
            self._socket = None
        if self._snapshot_thread:
            self._snapshot_thread.join(timeout=1.0)
        try:
            self.control_path.unlink()
        except FileNotFoundError:
            pass
