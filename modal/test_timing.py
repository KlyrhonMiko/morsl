import io
import json
import unittest
from contextlib import redirect_stdout

from timing import Timing


class TimingTests(unittest.TestCase):
    def test_completed_gpu_work_is_included_and_records_correlate(self):
        ticks = iter((0, 1, 4, 5))
        calls = []
        output = io.StringIO()
        with redirect_stdout(output):
            with Timing("segment", clock=lambda: next(ticks), request_id="request") as timing:
                with timing.stage("encoder", lambda: calls.append("sync")):
                    calls.append("work")
        record = json.loads(output.getvalue())
        self.assertEqual(calls, ["sync", "work", "sync"])
        self.assertEqual(record["stages_ms"], {"encoder": 3000})
        self.assertEqual(record["total_ms"], 5000)
        self.assertEqual(record["request_id"], "request")
        self.assertEqual(record["status"], "success")

    def test_failures_are_logged_without_exposing_error_content(self):
        output = io.StringIO()
        with redirect_stdout(output):
            with self.assertRaisesRegex(ValueError, "private content"):
                with Timing("startup") as timing:
                    with timing.stage("model_load"):
                        raise ValueError("private content")
        record = json.loads(output.getvalue())
        self.assertEqual(record["status"], "error")
        self.assertEqual(record["error_type"], "ValueError")
        self.assertIn("model_load", record["stages_ms"])
        self.assertNotIn("private content", output.getvalue())


if __name__ == "__main__":
    unittest.main()
