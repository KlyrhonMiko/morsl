"""Structured wall-clock timings for Modal logs; never records image or auth data."""
import json
import time
from contextlib import contextmanager


class Timing:
    def __init__(self, operation, *, clock=time.perf_counter, **metadata):
        self.clock = clock
        self.started = clock()
        self.record = {"event": "sam3_timing", "operation": operation, **metadata}
        self.stages = {}

    def __enter__(self):
        return self

    @contextmanager
    def stage(self, name, synchronize=None):
        # CUDA launches are asynchronous. Synchronize at both boundaries so a
        # stage measures completed GPU work rather than just launch overhead.
        if synchronize is not None:
            synchronize()
        started = self.clock()
        try:
            yield
            if synchronize is not None:
                synchronize()
        finally:
            self.stages[name] = round((self.clock() - started) * 1000, 3)

    def __exit__(self, error_type, error, traceback):
        self.record.update(
            status="success" if error_type is None else "error",
            total_ms=round((self.clock() - self.started) * 1000, 3),
            stages_ms=self.stages,
        )
        if error_type is not None:
            self.record["error_type"] = error_type.__name__
        print(json.dumps(self.record, separators=(",", ":")), flush=True)
        return False
