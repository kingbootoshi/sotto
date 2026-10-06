"""Make the bundled fp16 Parakeet model (1.27 GB, vs 2.4 GB fp32).

Downloads istupakov/parakeet-tdt-0.6b-v2-onnx (fp32) and converts the encoder
to fp16 -> models/parakeet-tdt-0.6b-v2-fp16. Verified: same transcript, ~225 ms
for 11.5 s of audio on DirectML (RTX 5070)."""
import shutil
from pathlib import Path

import onnx
from huggingface_hub import snapshot_download
from onnxconverter_common import float16

HERE = Path(__file__).resolve().parent
OUT = HERE / "models" / "parakeet-tdt-0.6b-v2-fp16"
WORK = HERE / "build" / "fp16-work"


def main():
    if (OUT / "encoder-model.onnx").exists():
        print("already exists:", OUT)
        return
    snap = Path(snapshot_download("istupakov/parakeet-tdt-0.6b-v2-onnx",
                                  allow_patterns=["config.json", "vocab.txt", "decoder_joint-model.onnx",
                                                  "encoder-model.onnx", "encoder-model.onnx.data"]))
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    for f in ("config.json", "vocab.txt", "decoder_joint-model.onnx"):
        shutil.copy(snap / f, OUT / f)
    # Model is >2 GB: shape inference must go file->file, then convert without it.
    shutil.copy(snap / "encoder-model.onnx.data", WORK / "encoder-model.onnx.data")
    onnx.shape_inference.infer_shapes_path(str(snap / "encoder-model.onnx"), str(WORK / "encoder-model.onnx"))
    m = onnx.load(str(WORK / "encoder-model.onnx"))
    m16 = float16.convert_float_to_float16(m, keep_io_types=True, disable_shape_infer=True)
    # The converter leaves some Casts targeting fp32 whose outputs it retyped to fp16.
    vi = {v.name: v.type.tensor_type.elem_type for v in m16.graph.value_info}
    fixed = 0
    for node in m16.graph.node:
        if node.op_type == "Cast" and vi.get(node.output[0]) == onnx.TensorProto.FLOAT16:
            for a in node.attribute:
                if a.name == "to" and a.i == onnx.TensorProto.FLOAT:
                    a.i = onnx.TensorProto.FLOAT16
                    fixed += 1
    onnx.save(m16, str(OUT / "encoder-model.onnx"), save_as_external_data=True,
              all_tensors_to_one_file=True, location="encoder-model.onnx.data")
    shutil.rmtree(WORK, ignore_errors=True)
    size = sum(p.stat().st_size for p in OUT.iterdir()) / 1e9
    print(f"wrote {OUT} ({size:.2f} GB, fixed {fixed} casts)")


if __name__ == "__main__":
    main()
