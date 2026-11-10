"""Shared helpers of the HD pack builder (tools/hd/build_pack.py). From ROTKPort tools/hdui (2026-11-06).

Upscaler (HD_ENGINE, default auto):
  esrgan   Real-ESRGAN (ncnn-vulkan) in NFSU2Port/work/realesrgan/x (copied from ROTKPort/.cache, the owner-approved download): the best detail; a download
           (github.com/xinntao/Real-ESRGAN, release v0.2.5.0) that needs the owner's OK (R-C7);
  metalfx  tools/hdui/upscale.swift: Apple's MetalFX spatial scaler, local, no model files;
  lanczos  tools/hdui/upscale.swift: Core Image Lanczos + unsharp mask;
  auto     esrgan when installed, else metalfx.
Either way hdfix joins colour and alpha and corrects the tones to the original afterwards.
"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
# NFSU2_ESRGAN / NFSU2_HD_BIN: other locations of Real-ESRGAN and prebuilt tools
ESRGAN = os.environ.get("NFSU2_ESRGAN") or os.path.join(HERE, "..", "..", "work", "realesrgan", "x")
# Caches (census runs, tools, packs) live in the repo's git-ignored out/hd (owner rule 2026-11-05:
# nothing new under ~/), or $HD_CACHE.
CACHE = os.environ.get("HD_CACHE") or os.path.join(HERE, "..", "..", "work", "hd")
TOOLS = os.path.join(CACHE, "bin")


def tool(name):
    """Compiles tools/hd/<name>.swift once (rebuilt when the source is newer); NFSU2_HD_BIN: prebuilt."""
    if os.environ.get("NFSU2_HD_BIN"):
        return os.path.join(os.environ["NFSU2_HD_BIN"], name)
    os.makedirs(TOOLS, exist_ok=True)
    exe, src = os.path.join(TOOLS, name), os.path.join(HERE, name + ".swift")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        subprocess.run(["swiftc", "-O", "-o", exe, src], check=True)
    return exe


def engine():
    e = os.environ.get("HD_ENGINE", "auto")
    if e == "auto":
        e = "esrgan" if os.path.exists(os.path.join(ESRGAN, "realesrgan-ncnn-vulkan")) else "metalfx"
    return e


def upscale4(inp, out, model="realesrgan-x4plus"):
    """Every PNG of inp -> out, 4x (the engine above). Returns the engine used."""
    e = engine()
    os.makedirs(out, exist_ok=True)
    if e == "esrgan":
        subprocess.run([os.path.join(ESRGAN, "realesrgan-ncnn-vulkan"), "-i", inp, "-o", out, "-n", model, "-m",
                        os.path.join(ESRGAN, "models"), "-f", "png"],
                       check=True, cwd=out, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.run([tool("upscale"), inp, out, "4", e], check=True, stdout=subprocess.DEVNULL)
    return e


def find_png(h, dirs):
    for d in dirs:
        p = os.path.join(d, h + ".png")
        if os.path.exists(p):
            return p
    return None
