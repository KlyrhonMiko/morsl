"""Exercise worker lifecycle without a GPU or a Modal deployment."""
import ast
import io
import unittest
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from uuid import uuid4


def worker_class(snapshots=True):
    # Execute the actual lifecycle methods, omitting only Modal's decorators
    # and deployment configuration so tests never contact the cloud.
    tree = ast.parse(Path(__file__).with_name("app.py").read_text())
    worker = next(node for node in tree.body
                  if isinstance(node, ast.ClassDef) and node.name == "SAM3Segmentation")
    worker.decorator_list = []
    for method in worker.body:
        if isinstance(method, ast.FunctionDef):
            method.decorator_list = []
    namespace = {"uuid4": uuid4, "GPU_SNAPSHOTS": snapshots,
                 "model_cache": Mock()}
    exec(compile(ast.Module(body=[worker], type_ignores=[]), "app.py", "exec"), namespace)
    return namespace["SAM3Segmentation"], namespace["model_cache"]


class SnapshotTests(unittest.TestCase):
    def test_restored_workers_get_unique_ids_and_reset_request_counts(self):
        worker, _ = worker_class()
        captured = worker()
        captured.snapshot_id = "shared-snapshot"
        captured.processor = object()
        clones = [worker(), worker()]
        with redirect_stdout(io.StringIO()):
            for clone in clones:
                clone.__dict__.update(captured.__dict__)
                clone.request_count = 17
                clone.ready()
        self.assertNotEqual(clones[0].worker_id, clones[1].worker_id)
        for clone in clones:
            self.assertEqual(clone.request_count, 0)
            self.assertEqual(clone.snapshot_id, "shared-snapshot")
            self.assertIs(clone.processor, captured.processor)

    def test_capture_warms_all_prompts_without_storing_image_state(self):
        self.check_setup(snapshots=True)

    def test_rollback_loads_model_without_snapshot_warmup(self):
        self.check_setup(snapshots=False)

    def check_setup(self, snapshots):
        worker, cache = worker_class(snapshots)
        processor = Mock()
        state = {}
        processor.set_image.return_value = state
        build = Mock(return_value=object())
        factory = Mock(return_value=processor)
        torch = SimpleNamespace(
            cuda=SimpleNamespace(synchronize=Mock(), empty_cache=Mock()),
            inference_mode=nullcontext, autocast=lambda *args, **kwargs: nullcontext(),
            bfloat16=object(),
        )
        modules = {"torch": torch,
                   "sam3.model_builder": SimpleNamespace(build_sam3_image_model=build),
                   "sam3.model.sam3_image_processor": SimpleNamespace(Sam3Processor=factory)}
        instance = worker()
        with patch.dict("sys.modules", modules), redirect_stdout(io.StringIO()):
            instance.setup()
        build.assert_called_once_with()
        cache.commit.assert_called_once_with()
        self.assertEqual(set(instance.__dict__), {"snapshot_id", "processor"})
        if snapshots:
            self.assertEqual(processor.set_image.call_args.args[0].size, (1600, 1200))
            self.assertEqual([call.kwargs["prompt"] for call in
                              processor.set_text_prompt.call_args_list],
                             ["plate", "bowl", "food tray"])
            torch.cuda.empty_cache.assert_called_once_with()
        else:
            processor.set_image.assert_not_called()


if __name__ == "__main__":
    unittest.main()
