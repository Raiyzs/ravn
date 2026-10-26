# Why local AI breaks on AMD + atomic Linux

Field notes from getting ComfyUI, Ollama, Wan2GP and Unsloth running on an RX 9070 XT
under Bazzite. Each entry is an error people hit, the cause, and what ravn does about it.
If you don't use ravn, the fixes still apply by hand.

---

## 0. You don't need to install ROCm

On Bazzite, Silverblue, Kinoite, Bluefin, Aurora or SteamOS you can't `dnf install rocm`,
and most guides stop there or send you into a distrobox.

You don't need either. The PyTorch ROCm wheels from `download.pytorch.org/whl/rocm7.2`
carry the whole ROCm user-space runtime inside them. All they need from the host is the
`amdgpu` kernel driver and `/dev/kfd`, which every distro with a modern kernel already has.
Same for Ollama's ROCm build: it ships its own libraries.

**ravn:** installs everything into a Python 3.12 venv under `~/ravn`. No system packages,
no containers, no sudo.

---

## 1. `hipErrorInvalidDeviceFunction` / `HIP error: invalid device function`

**Cause:** your Ryzen CPU has an integrated GPU (most Ryzen 7000/9000 desktop chips do; the "F" models don't).
ROCm sees it as a second device. PyTorch, Unsloth or bitsandbytes then dispatch kernels to
the iGPU, which has a different architecture (`gfx1036` next to your `gfx1201`), and the
kernel doesn't exist for it.

**Fix:** pin apps to the discrete card:

```bash
HIP_VISIBLE_DEVICES=0 CUDA_VISIBLE_DEVICES=0 python main.py
```

The index is ROCm's order, not `lspci`'s. Check `/sys/class/kfd/kfd/topology/nodes/*/properties`
(nodes with `gfx_target_version 0` are CPUs and don't count).

**ravn:** reads the KFD topology, picks the GPU with the most VRAM and pins every app to it.
`ravn doctor` shows which card it chose and why.

---

## 2. Your RX 6600 / 6700 XT "isn't supported"

**Cause:** PyTorch ships kernels for a fixed list of chips. `gfx1030` (RX 6800/6900) is on it;
`gfx1031`, `gfx1032` (RX 6700 XT, 6600) are not. They are instruction-compatible with a chip
that is. (The 780M, `gfx1103`, got native kernels in the ROCm 7.2 wheels; older wheels and
Ollama still need the override.)

**Fix:** tell the runtime to use the neighbour's kernels:

| GPU | gfx | override |
|---|---|---|
| RX 6700 XT, 6600, 6500, Steam Deck | gfx1031–1036 | `HSA_OVERRIDE_GFX_VERSION=10.3.0` |
| Radeon 780M / 760M | gfx1103 | none with torch rocm7.2; `11.0.0` for older wheels and Ollama |
| RX 7000, RX 9000, Strix Halo | gfx110x, gfx120x, gfx1151 | none needed |

**Trap:** setting this globally in `~/.bashrc` breaks every *other* GPU, including the one
it wasn't meant for, and it applies to all GPUs in the machine at once.

**ravn:** works out the override from the GPU and the actual kernel list inside the installed
PyTorch (`torch.cuda.get_arch_list()`), sets it per app, and ignores a global one.

---

## 3. `pip install` inside a uv venv installs somewhere else

**Cause:** `uv venv` creates a venv *without* pip. Activate it, type `pip install x`, and your
shell finds `~/.local/bin/pip` from the host Python instead. No error, it just installs into
`~/.local/lib/python3.14/site-packages`. If that's where your working ROCm torch lives,
you've just changed it.

**Fix:** use `uv pip install`, or create venvs with `uv venv --seed`.

**ravn:** every venv is created with `--seed`, so ComfyUI-Manager and custom nodes use the
venv's own pip. `ravn doctor` warns if PyTorch sits in your user site.

---

## 4. A custom node replaced your ROCm torch with the CUDA one

**Symptoms:** ComfyUI suddenly runs on CPU, or prints `Torch not compiled with CUDA enabled`
or `Found no NVIDIA driver on your system` on a machine that has never seen NVIDIA.

**Cause:** a node's `requirements.txt` lists `torch` (or something that needs a newer one), pip
resolves it from PyPI, and PyPI's torch is the CUDA build. It also pulls 3–4 GB of
`nvidia-*` wheels.

**ravn:** ComfyUI starts with `PIP_CONSTRAINT` and `UV_CONSTRAINT` pointing at the exact ROCm
versions it was verified with, so pip keeps them. If something still slips through,
`ravn run comfyui` notices before launch (it checks the installed packages, instantly) and
puts the ROCm build back. `ravn heal comfyui` does it on demand.

---

## 5. `hipDrvLaunchKernelEx`, `hip_utils.so could not be loaded`, or tensors "on cuda:0 and cpu"

**Cause:** plain `triton` from PyPI and the ROCm build (`triton-rocm`, formerly
`pytorch-triton-rocm`) install into the same `triton/` folder. Whichever goes in last wins.
`pip show` still reports the ROCm one; only `python -c "import triton; print(triton.__version__)"`
tells the truth. Plain triton's AMD backend calls HIP functions that don't exist in the ROCm
runtime bundled with your torch, so fused kernels fail. Some libraries then fall back
half-way and crash with `Expected all tensors to be on the same device, cuda:0 and cpu`.

It usually arrives as a dependency of something else: `flash-linear-attention` is a known one.

**Fix:** `pip uninstall triton`, then force-reinstall the ROCm triton with `--no-deps`.

**ravn:** blocks plain `triton` from every resolution (`uv --override`), detects it in the
pre-launch check, and removes it when healing.

---

## 6. `Memory access fault by GPU node` with `expandable_segments`

**Cause:** `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` is a common VRAM tip for NVIDIA.
On ROCm builds it crashes the process (exit -6, memory access fault), seen on gfx1201.

**ravn:** strips `expandable_segments` from `PYTORCH_*_ALLOC_CONF` for its apps, and
`ravn doctor` points it out if it's set in your shell.

---

## 7. `torch.compile is not supported on Python 3.14+`

**Cause:** Fedora 44 (and Bazzite on it) ships Python 3.14. PyTorch's compiler, and therefore
Unsloth and anything else that compiles kernels, refuses to run there.

**ravn:** uses a uv-managed Python 3.12 for every app. Nothing touches the system Python.

---

## 8. CUDA-only packages in upstream requirements

`onnxruntime-gpu`, `nvidia-ml-py`, `--extra-index-url .../cuda...`: projects written on NVIDIA
machines list these without a second thought. `onnxruntime-gpu` in particular shadows the CPU
`onnxruntime` and drags in CUDA libraries.

**ravn:** blocks `onnxruntime-gpu` from resolution and removes stray `nvidia-*` wheels when
healing.

---

## 9. bitsandbytes can't detect your GPU (no `rocminfo`)

**Cause:** bitsandbytes shells out to `rocminfo` to learn the arch. Atomic distros don't
ship it.

**Fix:** a two-line shim on your `PATH` named `rocminfo` that prints
`Name: gfx1201` and `Wavefront Size: 32(0x20)`. (ravn will do this when it gains a
fine-tuning recipe.)

---

## 10. The first image takes minutes, then it's fast

**Cause:** MIOpen benchmarks convolution kernels the first time it sees a new shape. Current
ComfyUI sidesteps this by turning MIOpen off on AMD (`cudnn.enabled = False`, you'll see it in
the log); other PyTorch apps don't, and their first run can sit there tuning.

**ravn:** sets `MIOPEN_FIND_MODE=FAST`. Put `MIOPEN_FIND_MODE=NORMAL` in `~/ravn/ravn.env` if
you'd rather pay the tuning once for slightly faster kernels.

---

## 11. Cosmetic: the GPU shows as "AMD Radeon Graphics"

PyTorch's bundled libdrm looks for the name table at `/opt/amdgpu/share/libdrm/amdgpu.ids`.
Your distro keeps it at `/usr/share/libdrm/amdgpu.ids`. Harmless. `ravn doctor` reads the
right file.

---

Found another one? [File a GPU report](https://github.com/Raiyzs/ravn/issues/new?template=gpu-report.yml) with the output of `ravn doctor --share`.
