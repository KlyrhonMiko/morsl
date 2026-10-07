"""Deploy with `modal deploy modal/app.py` from the repository root."""
import os
from pathlib import Path
from uuid import uuid4

import modal

app = modal.App("sam3-deployment")
source = Path(__file__).parent
SAM3_REVISION = "2345a4ad109ac29c569da749c91d84f10dc08c40"
# Set False and redeploy to compare the original startup path or roll back.
GPU_SNAPSHOTS = True
api_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install("fastapi==0.142.2", "httpx==0.28.1", "python-multipart==0.0.32",
                 "Pillow==12.2.0", "numpy==1.26.4", "scipy==1.16.3")
    .add_local_dir(source, "/root/segmentation", copy=True)
    .env({"PYTHONPATH": "/root/segmentation"})
)
gpu_image = (
    modal.Image.from_registry(
        "nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04", add_python="3.12",
    )
    .apt_install("git")
    .pip_install("torch==2.10.0", "torchvision==0.25.0",
                 index_url="https://download.pytorch.org/whl/cu128")
    .pip_install("Pillow==12.2.0", "scipy==1.16.3", "einops", "huggingface_hub",
                 "sam3 @ git+https://github.com/facebookresearch/sam3.git@" + SAM3_REVISION)
    # SAM3's model builder imports these without declaring them as core dependencies.
    .pip_install("pycocotools==2.0.10", "psutil==7.0.0")
    # Check imports before deploying; this does not download weights or need a GPU.
    .run_commands(
        "python -c 'from sam3.model_builder import build_sam3_image_model; "
        "from sam3.model.sam3_image_processor import Sam3Processor'"
    )
    .add_local_dir(source, "/root/segmentation", copy=True)
    .env({"PYTHONPATH": "/root/segmentation", "HF_HOME": "/cache/huggingface"})
)
model_cache = modal.Volume.from_name("sam3-model-cache", create_if_missing=True)


@app.cls(image=gpu_image, gpu="L4", timeout=110, startup_timeout=600,
         enable_memory_snapshot=GPU_SNAPSHOTS,
         experimental_options={"enable_gpu_snapshot": True} if GPU_SNAPSHOTS else {},
         max_containers=1, volumes={"/cache": model_cache},
         secrets=[modal.Secret.from_name("sam3-huggingface")])
class SAM3Segmentation:
    @modal.enter(snap=True)
    def setup(self):
        from timing import Timing

        # This ID identifies the captured model state, not a restored worker.
        self.snapshot_id = uuid4().hex
        with Timing("snapshot_prepare" if GPU_SNAPSHOTS else "startup",
                    snapshot_id=self.snapshot_id) as timing:
            with timing.stage("imports"):
                import torch
                from sam3.model_builder import build_sam3_image_model
                from sam3.model.sam3_image_processor import Sam3Processor
                # Include CPU mask-processing imports in the snapshot too.
                import image_contract
            with timing.stage("model_load", torch.cuda.synchronize):
                self.processor = Sam3Processor(
                    build_sam3_image_model(), confidence_threshold=0.5,
                )
            with timing.stage("cache_commit"):
                model_cache.commit()
            if GPU_SNAPSHOTS:
                with timing.stage("warmup", torch.cuda.synchronize):
                    from PIL import Image

                    # Synthetic data only: no user's photo is captured. Keep
                    # image features local so the snapshot holds only the model.
                    with torch.inference_mode(), torch.autocast("cuda", dtype=torch.bfloat16):
                        state = self.processor.set_image(Image.new("RGB", (1600, 1200)))
                        for prompt in ("plate", "bowl", "food tray", "serving board", "food"):
                            self.processor.reset_all_prompts(state)
                            self.processor.set_text_prompt(state=state, prompt=prompt)
                    del state
                with timing.stage("release_warmup_buffers"):
                    import gc

                    gc.collect()
                    torch.cuda.empty_cache()

    @modal.enter(snap=False)
    def ready(self):
        from timing import Timing

        # Fresh values on every restore; IDs/counters in setup would be copied
        # to all workers restored from the same snapshot.
        with Timing("worker_ready", snapshot_id=self.snapshot_id,
                    snapshots_enabled=GPU_SNAPSHOTS) as timing:
            self.worker_id = uuid4().hex
            self.request_count = 0
            timing.record["worker_id"] = self.worker_id

    @modal.method()
    def segment(self, data: bytes, request_id: str = ""):
        from timing import Timing

        self.request_count += 1
        with Timing("segment", request_id=request_id, worker_id=self.worker_id,
                    first_request=self.request_count == 1) as timing:
            with timing.stage("imports"):
                import torch
                from image_contract import (encode_plates, open_photo,
                                            prepare_dish_candidates, prepare_serving_boards,
                                            group_serving_boards)
            with timing.stage("image_decode"):
                photo = open_photo(data)
            candidates = []
            food_candidates = []
            board_candidates = []
            vessel_candidates = []
            with torch.inference_mode(), torch.autocast("cuda", dtype=torch.bfloat16):
                with timing.stage("image_encoder", torch.cuda.synchronize):
                    state = self.processor.set_image(photo)
                for prompt in ("plate", "bowl", "food tray", "serving board", "food"):
                    with timing.stage("prompt_" + prompt.replace(" ", "_"),
                                      torch.cuda.synchronize):
                        self.processor.reset_all_prompts(state)
                        output = self.processor.set_text_prompt(state=state, prompt=prompt)
                    with timing.stage("transfer_" + prompt.replace(" ", "_")):
                        masks = output["masks"].detach().cpu().numpy()
                        # Autocast scores may be bfloat16, which NumPy cannot represent.
                        scores = output["scores"].detach().float().cpu().numpy()
                        detected = [(mask[0], float(score))
                                    for mask, score in zip(masks, scores)]
                        if prompt == "food":
                            food_candidates.extend(detected)
                        elif prompt == "serving board":
                            board_candidates.extend(detected)
                        else:
                            candidates.extend(detected)
                            if prompt in ("plate", "bowl"):
                                vessel_candidates.extend(detected)
            with timing.stage("mask_cleanup"):
                completed = prepare_dish_candidates(
                    candidates, *photo.size, food_candidates=food_candidates,
                )
                vessels = (prepare_dish_candidates(vessel_candidates, *photo.size)
                           if board_candidates else [])
                boards = prepare_serving_boards(
                    board_candidates, *photo.size, food_candidates, vessels,
                )
                if boards:
                    components = vessels + [(mask, score) for mask, score in food_candidates
                                             if score >= 0.5]
                    completed = group_serving_boards(completed, boards, components)
            with timing.stage("mask_encode"):
                result = encode_plates(completed, *photo.size)
            timing.record.update(image_size=list(photo.size), candidates=len(candidates),
                                 food_candidates=len(food_candidates),
                                 board_candidates=len(board_candidates),
                                 serving_boards=len(boards),
                                 plates=len(result["plates"]))
            return result


@app.function(image=api_image, timeout=180, max_containers=1,
              secrets=[modal.Secret.from_name(
                  "sam3-auth", required_keys=["SUPABASE_URL", "SUPABASE_ANON_KEY"],
              )])
@modal.concurrent(max_inputs=20)
@modal.asgi_app(label="sam3-deployment-segment")
def api():
    from cloud_api import SupabaseAuthenticator, create_api

    authenticate = SupabaseAuthenticator(
        os.environ["SUPABASE_URL"], os.environ["SUPABASE_ANON_KEY"],
    )
    worker = SAM3Segmentation()

    async def segment(data):
        from timing import Timing

        request_id = uuid4().hex
        with Timing("remote_call", request_id=request_id):
            return await worker.segment.remote.aio(data, request_id=request_id)

    return create_api(segment, authenticate)
