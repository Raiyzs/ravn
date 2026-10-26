<p align="center"><img src="docs/icon.svg" width="72" alt=""></p>

<h1 align="center">ravn</h1>

<p align="center"><b>Local AI on your AMD GPU, for Bazzite and every atomic Linux.</b><br>
ComfyUI and Ollama on ROCm in one command. No sudo, no distrobox, no CUDA wheels.</p>

<p align="center">
<a href="https://raiyzs.github.io/ravn/">Website</a> ·
<a href="docs/GOTCHAS.md">Why it breaks</a> ·
<a href="#support">Support</a>
</p>

---

```bash
curl -fsSL https://raw.githubusercontent.com/Raiyzs/ravn/main/install.sh | bash
```

That puts one bash script at `~/.local/bin/ravn` and runs `ravn doctor`.
[Read the installer first](install.sh) — it is 23 lines.

```bash
ravn install comfyui      # ROCm PyTorch + ComfyUI + Manager, verified on your GPU
ravn run comfyui --open   # or "ComfyUI (ravn)" in your app menu
ravn install ollama       # official ROCm build, user space
ravn enable ollama        # run it at login
```

## On an RX 9070 XT

<p align="center"><img src="docs/first-image.png" width="384" alt="SD 1.5 test image: a raven on a frozen fjord"></p>

Measured on the machine ravn was built on (Bazzite 44, RX 9070 XT, Ryzen 9800X3D):

| | |
|---|---|
| `ravn install comfyui --starter` | ~20 min on an 8 MB/s line, nearly all of it the 6 GB PyTorch wheel |
| ComfyUI start | 7 s |
| SD 1.5, 512×512, 20 steps | 3.6 s for the first image (model load), then 1.5 s each (~26 it/s) |
| `ravn verify comfyui` | 4k fp16 matmul in 1.79 ms, ~77 TFLOPS, checked against CPU |
| heal after a CPU torch + plain triton swap | about 5 s, back on the GPU |
| Ollama, qwen2.5:0.5b | 208 tokens/s, `ollama ps` shows 100% GPU |
| disk | ~25 GB: 17 GB venv, 6 GB wheel kept for healing, 2 GB starter model |

## Why

On Bazzite, Silverblue, Kinoite, Bluefin, Aurora and SteamOS you can't `dnf install rocm`,
and most guides end there or in a distrobox. You don't need either: the PyTorch ROCm wheels
carry their own runtime, and Ollama's ROCm build ships its own libraries. All the host needs
is the `amdgpu` kernel driver, which it already has.

What actually stops people is a handful of traps that fail silently or with an error that
points the wrong way. ravn knows them:

| Trap | What you see | What ravn does |
|---|---|---|
| Ryzen iGPU is ROCm device #1 | `hipErrorInvalidDeviceFunction` | pins apps to the discrete GPU |
| RX 6600/6700 XT not in PyTorch's list | runs on CPU | sets the right `HSA_OVERRIDE_GFX_VERSION`, per app |
| a custom node pip-installs CUDA torch | `Found no NVIDIA driver`, CPU only | pins the ROCm build, heals it before launch |
| plain `triton` overwrites the ROCm one | `hipDrvLaunchKernelEx`, tensors on `cuda:0 and cpu` | blocks it, removes it |
| `pip` inside a uv venv | installs into your host Python | venvs carry their own pip |
| `expandable_segments` VRAM tip | `Memory access fault by GPU node` | strips it |
| Fedora's Python 3.14 | `torch.compile is not supported` | uses Python 3.12 |

The long version, with fixes you can apply by hand: **[Why local AI breaks on AMD + atomic Linux](docs/GOTCHAS.md)**.

## `ravn doctor`

Checks the driver, `/dev/kfd`, every GPU ROCm can see, your shell for overrides that break
things, and any installed apps. Real output from an RX 9070 XT:

```
 System
  ✓ Bazzite 44 (bazzite-dx), atomic · kernel 7.2.9
  ✓ amdgpu kernel driver loaded
  ✓ /dev/kfd is accessible

 GPUs
  ✓ [0] AMD Radeon RX 9070 XT · gfx1201 · 16 GB · PyTorch ROCm: native
  · [1] Granite Ridge [Radeon 610M] · gfx1036 · 2.0 GB — hidden from AI apps
  ! 2 GPUs visible to ROCm — ravn pins its apps to [0] (HIP_VISIBLE_DEVICES=0)
      unpinned, PyTorch can send kernels to the iGPU: hipErrorInvalidDeviceFunction

 Verdict: ready. Your AMD Radeon RX 9070 XT runs ROCm natively.
```

`ravn doctor --share` prints the same without colour, ready to paste into an issue.
`ravn check <venv>` runs the PyTorch checks against any venv, ravn's or not.

## GPUs

| Family | Examples | ComfyUI (PyTorch) | Ollama |
|---|---|---|---|
| RDNA4 · gfx120x | RX 9070 XT, 9070, 9060 XT, AI PRO R9700 | native · tested | ROCm |
| RDNA3 · gfx110x | RX 7900 XTX, 7800 XT, 7600 | native | ROCm |
| RDNA3.5 · gfx115x | Strix Halo, Strix Point | native | ROCm |
| RDNA3 iGPU · gfx1103 | Radeon 780M, 760M | native | ROCm + override |
| RDNA2 · gfx1030 | RX 6800, 6900 XT | native | ROCm |
| RDNA2 · gfx1031–1036 | RX 6700 XT, 6600, 6500, Steam Deck | override 10.3.0 | ROCm + override |
| Polaris, RDNA1 | RX 580, 5700 XT | CPU / experimental | Vulkan |

"Tested" means on my own hardware. Everything else follows from the kernels compiled into
PyTorch 2.14.1 for ROCm 7.2; if your card behaves differently, please open an issue with
`ravn doctor --share`.

## What it changes on your system

Everything lives in `~/ravn` (`RAVN_HOME`). Outside it, ravn writes:

- `~/.local/bin/ravn` (itself) and, if no other `ollama` is on your `PATH`, an `ollama` shim
- `~/.local/share/applications/ravn-comfyui.desktop` and an icon
- `~/.config/systemd/user/ravn-ollama.service`, only if you run `ravn enable ollama`
- `uv` into `~/.local/bin` if you don't have it

No sudo, no layered packages, no containers, no edits to your shell profile.
The 6 GB PyTorch wheel stays in `~/ravn/.ravn/wheels` so healing never downloads it twice.
`ravn remove <app>` asks before deleting models.

## Settings

Put overrides in `~/ravn/ravn.env`, one `KEY=value` per line. They win over ravn's choices.

```bash
RAVN_COMFY_LISTEN=0.0.0.0        # reach ComfyUI from other devices
RAVN_OLLAMA_HOST=127.0.0.1:11435 # if something else uses 11434
MIOPEN_FIND_MODE=NORMAL          # tune conv kernels once instead of skipping it
```

`ravn env comfyui` shows exactly what the app will run with.

## Roadmap

- Wan2GP (video) with the LTX fixes from [GOTCHAS](docs/GOTCHAS.md)
- Open WebUI on top of ravn's Ollama
- Local QLoRA fine-tuning (Unsloth), including the `rocminfo` shim bitsandbytes needs
- Kokoro TTS

## Support

ravn is free and MIT-licensed. If it saved you a weekend, **[pay what you want](https://buy.stripe.com/bJe6oG4IKgfIdvhgbBcfK03)**
(suggested $9). It funds the roadmap above. Stars and bug reports help just as much.

## Development

```bash
bash tests/run.sh    # offline: fake GPU trees for RDNA2/3/4, iGPU-first ordering, Polaris, no GPU
shellcheck ravn
```

Made in Tromsø by [KSV](https://github.com/Raiyzs). MIT.
