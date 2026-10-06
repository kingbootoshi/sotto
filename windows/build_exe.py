r"""Build the shareable Windows app:  dist/Sotto/Sotto.exe  +  dist/Sotto-windows-x64.zip

Prereqs (once):  py -3.13 -m venv .venv-build
                 .venv-build\Scripts\python -m pip install -r requirements-exe.txt
Then:            .venv-build\Scripts\python build_exe.py
The fp16 model is produced by tools_make_fp16.py (or reused from models/)."""
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = HERE / "models" / "parakeet-tdt-0.6b-v2-fp16"
DIST = HERE / "dist"
ICON = HERE / "build" / "sotto.ico"

if not (MODEL / "encoder-model.onnx").exists():
    sys.exit(f"missing {MODEL} - run tools_make_fp16.py first")

ICON.parent.mkdir(exist_ok=True)
from PIL import Image  # noqa: E402
Image.open(HERE.parent / "scripts" / "icon" / "icon_1024.png").save(
    ICON, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

subprocess.check_call([
    sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--windowed",
    "--name", "Sotto", "--icon", str(ICON),
    "--distpath", str(DIST), "--workpath", str(HERE / "build" / "pyi"), "--specpath", str(HERE / "build"),
    "--collect-all", "onnx_asr", "--collect-binaries", "onnxruntime",
    "--collect-data", "soundcard", "--collect-all", "sounddevice", "--collect-all", "_sounddevice_data",
    "--hidden-import", "pystray._win32",
    "--exclude-module", "onnx", "--exclude-module", "onnxconverter_common", "--exclude-module", "torch",
    "--exclude-module", "huggingface_hub", "--exclude-module", "matplotlib", "--exclude-module", "pytest",
    str(HERE / "sotto_main.py"),
])

app = DIST / "Sotto"
dst = app / "models" / MODEL.name
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(MODEL, dst)
shutil.copy(HERE / "README-windows.md", app / "README.txt")

zp = DIST / "Sotto-windows-x64.zip"
zp.unlink(missing_ok=True)
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
    for f in app.rglob("*"):
        if f.is_file():
            # model weights barely compress; store them to keep zipping fast
            ct = zipfile.ZIP_STORED if f.suffix in (".data", ".onnx") else zipfile.ZIP_DEFLATED
            z.write(f, Path("Sotto") / f.relative_to(app), compress_type=ct)
print(f"built {app / 'Sotto.exe'}\nzip {zp} {zp.stat().st_size / 1e9:.2f} GB")
