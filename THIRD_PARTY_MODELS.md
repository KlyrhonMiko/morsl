# Offline dish models

The Android engine uses unmodified, publicly downloadable ONNX weights. Models
are downloaded once to the app's no-backup directory and verified with SHA-256.
The input photo is never transmitted to the model hosts.

| Component | Source revision | License |
| --- | --- | --- |
| Grounding DINO Tiny, quantized ONNX | [onnx-community/grounding-dino-tiny-ONNX](https://huggingface.co/onnx-community/grounding-dino-tiny-ONNX/tree/ff690b0a8050566c290287545bd059350f3e9096) | Apache-2.0; [original Grounding DINO](https://github.com/IDEA-Research/GroundingDINO) |
| MobileSAM encoder and SAM multi-mask decoder, ONNX export | [Acly/MobileSAM](https://huggingface.co/Acly/MobileSAM/tree/0d3b403339b4674a82493d5e97964dd78089ddc8) | Export repository declares MIT; original [MobileSAM](https://github.com/ChaoningZhang/MobileSAM) and [Segment Anything](https://github.com/facebookresearch/segment-anything) use Apache-2.0 |
| ONNX Runtime Android 1.23.2 | [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime) | MIT |

Model filenames, lengths, revisions and SHA-256 digests are pinned in
`android/app/src/main/kotlin/com/example/morsl/DishCutouts.kt`.
The detector uses the fixed BERT-tokenized prompt `plate . bowl . food tray .`.
The encoder uses RGB at longest edge 1024; normalization/padding are part of the
exported graph. Each box receives two corner prompts (labels 2, 3) and a positive
center (label 1). The decoder supplies four candidates; the highest predicted
IoU is selected. Cleanup keeps the largest connected component and fills enclosed
holes. The original RGB pixels are composited with the resulting alpha in Dart.

Recognition is best effort. The detection limit is 12 dishes per photo; tiny
objects covering less than 1.2% of the photo are excluded. Occluded and cropped
parts remain absent. The optional manual tools can correct difficult cases.

## Real-device regression

`DishCutoutsDeviceTest` is an opt-in instrumentation test for the supplied
four-dish regression photo. It reads only `cache/cutout-fixture/photo.png`,
with the three pinned weights pre-staged in `no_backup/dish-models-v1/`.
It verifies model hashes, runs actual native inference, asserts four nonempty
transparent masks, and saves masks plus bounds/timing in that same fixture folder.
No app database, account content, or saved memories are read by this test.
The private photo and generated outputs are not shipped in the app or committed.
