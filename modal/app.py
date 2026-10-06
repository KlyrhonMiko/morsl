"""Deploy with `modal deploy modal/app.py` from the repository root."""
import os
from pathlib import Path

import modal

app = modal.App("sam3-deployment")
source = Path(__file__).parent
SAM3_REVISION = "2345a4ad109ac29c569da749c91d84f10dc08c40"
api_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install("fastapi==0.142.2", "httpx==0.28.1", "python-multipart==0.0.32",
                 "Pillow==12.2.0", "numpy==1.26.4")
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
    .pip_install("Pillow==12.2.0", "einops", "huggingface_hub",
                 "sam3 @ git+https://github.com/facebookresearch/sam3.git@" + SAM3_REVISION)
    .add_local_dir(source, "/root/segmentation", copy=True)
    .env({"PYTHONPATH": "/root/segmentation", "HF_HOME": "/cache/huggingface"})
)
model_cache = modal.Volume.from_name("sam3-model-cache", create_if_missing=True)


@app.cls(image=gpu_image, gpu="L4", timeout=110, startup_timeout=600,
         max_containers=1, volumes={"/cache": model_cache},
         secrets=[modal.Secret.from_name("sam3-huggingface")])
class SAM3Segmentation:
    @modal.enter()
    def setup(self):
        from sam3.model_builder import build_sam3_image_model
        from sam3.model.sam3_image_processor import Sam3Processor

        self.processor = Sam3Processor(build_sam3_image_model(), confidence_threshold=0.5)
        model_cache.commit()

    @modal.method()
    def segment(self, data: bytes):
        import torch
        from image_contract import encode_plates, open_photo

        photo = open_photo(data)
        candidates = []
        with torch.inference_mode(), torch.autocast("cuda", dtype=torch.bfloat16):
            state = self.processor.set_image(photo)
            for prompt in ("plate", "bowl", "food tray"):
                self.processor.reset_all_prompts(state)
                output = self.processor.set_text_prompt(state=state, prompt=prompt)
                masks = output["masks"].detach().cpu().numpy()
                scores = output["scores"].detach().cpu().numpy()
                candidates.extend((mask[0], float(score))
                                  for mask, score in zip(masks, scores))
        return encode_plates(candidates, *photo.size)


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
        return await worker.segment.remote.aio(data)

    return create_api(segment, authenticate)
