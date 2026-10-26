#!/usr/bin/env bash
# Offline tests for ravn's detection and safety logic. No GPU, network or sudo needed.
# Each scenario builds a fake /sys tree and points RAVN_SYSFS at it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
PASS=0 FAIL=0

# mkgpu <sysroot> <kfd node> <gfx_target_version> <render minor> <vram bytes> <pci device id>
mkgpu() {
  local s=$1 node=$2 gtv=$3 minor=$4 vram=$5 dev=$6
  mkdir -p "$s/class/kfd/kfd/topology/nodes/$node" "$s/class/drm/renderD$minor/device" "$s/module/amdgpu"
  printf 'cpu_cores_count 0\nsimd_count 64\ngfx_target_version %s\ndrm_render_minor %s\n' "$gtv" "$minor" \
    > "$s/class/kfd/kfd/topology/nodes/$node/properties"
  echo "$vram" > "$s/class/drm/renderD$minor/device/mem_info_vram_total"
  echo "$dev" > "$s/class/drm/renderD$minor/device/device"
  echo 0xc0 > "$s/class/drm/renderD$minor/device/revision"
}
mkcpu() { # KFD always lists the CPU as node 0 with gfx_target_version 0
  mkdir -p "$1/class/kfd/kfd/topology/nodes/0"
  printf 'cpu_cores_count 16\nsimd_count 0\ngfx_target_version 0\n' > "$1/class/kfd/kfd/topology/nodes/0/properties"
}

IDS="$ROOT/amdgpu.ids"
printf '7550,\tC0,\tAMD Radeon RX 9070 XT\n73FF,\tC0,\tAMD Radeon RX 6600\n' > "$IDS"

envof() { # envof <sysroot> [app archs var]  -> the env lines ravn would launch with
  RAVN_SOURCED=1 RAVN_SYSFS="$1" RAVN_AMDGPU_IDS="$IDS" RAVN_HOME="$ROOT/home" \
    bash -c 'source ./ravn; gpu_env "${2:-$TORCH_ARCHS}"' _ "$1" "${2:-}"
}
fn() { # fn <sysroot> <shell snippet using ravn functions>
  RAVN_SOURCED=1 RAVN_SYSFS="$1" RAVN_AMDGPU_IDS="$IDS" RAVN_HOME="$ROOT/home" bash -c "source ./ravn; $2"
}
expect() { # expect <name> <haystack> <needle>
  if [[ $2 == *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s\n  wanted: %s\n  got:    %s\n' "$1" "$3" "${2//$'\n'/ | }"; fi
}
refute() {
  if [[ $2 != *"$3"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s\n  must not contain: %s\n  got: %s\n' "$1" "$3" "${2//$'\n'/ | }"; fi
}

# ── pure helpers ──
expect "gfx_name RDNA4"   "$(fn / 'gfx_name 120001')" gfx1201
expect "gfx_name MI200"   "$(fn / 'gfx_name 90010')"  gfx90a
expect "gfx_name Raphael" "$(fn / 'gfx_name 100306')" gfx1036
expect "hsa 1030"   "$(fn / 'gfx_to_hsa gfx1030')" 10.3.0
expect "hsa 90a"    "$(fn / 'gfx_to_hsa gfx90a')"  9.0.10
expect "hsa 1151"   "$(fn / 'gfx_to_hsa gfx1151')" 11.5.1
expect "target native" "$(fn / 'target gfx1201 "$TORCH_ARCHS"')" native
expect "target RX 6600" "$(fn / 'target gfx1032 "$TORCH_ARCHS"')" "override 10.3.0 gfx1030"
expect "target 780M native in rocm7.2" "$(fn / 'target gfx1103 "$TORCH_ARCHS"')" native
expect "target 780M on an older torch" "$(fn / 'target gfx1103 "gfx1030 gfx1100"')" "override 11.0.0 gfx1100"
expect "target Polaris" "$(fn / 'target gfx803 "$TORCH_ARCHS"')" none
expect "target 890M without its own kernels" "$(fn / 'target gfx1152 "gfx1100 gfx1151"')" "override 11.5.1 gfx1151"

# ── this machine's shape: RX 9070 XT + Ryzen iGPU ──
S="$ROOT/s1"; mkcpu "$S"; mkgpu "$S" 1 120001 128 17095983104 0x7550; mkgpu "$S" 2 100306 129 2147483648 0x13c0
E=$(envof "$S")
expect "dGPU+iGPU pins dGPU" "$E" "HIP_VISIBLE_DEVICES=0"
expect "dGPU+iGPU CUDA_VISIBLE too" "$E" "CUDA_VISIBLE_DEVICES=0"
refute "RDNA4 needs no override" "$E" HSA_OVERRIDE
expect "RDNA4 flash attention" "$E" TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
expect "marketing name by revision" "$(fn "$S" 'detect_gpus; echo "${GPU_NAME[0]}"')" "AMD Radeon RX 9070 XT"

# ── iGPU enumerated before the dGPU ──
S="$ROOT/s2"; mkcpu "$S"; mkgpu "$S" 1 100306 128 536870912 0x13c0; mkgpu "$S" 2 110000 129 25769803776 0x744c
E=$(envof "$S")
expect "iGPU-first pins index 1" "$E" "HIP_VISIBLE_DEVICES=1"
refute "7900 XTX needs no override" "$E" HSA_OVERRIDE

# ── RX 6600 alone ──
S="$ROOT/s3"; mkcpu "$S"; mkgpu "$S" 1 100302 128 8573157376 0x73ff
E=$(envof "$S")
expect "RX 6600 override" "$E" "HSA_OVERRIDE_GFX_VERSION=10.3.0"
refute "single GPU not pinned" "$E" HIP_VISIBLE_DEVICES
refute "RDNA2 no aotriton flag" "$E" AOTRITON

# ── 780M laptop APU ──
S="$ROOT/s4"; mkcpu "$S"; mkgpu "$S" 1 110003 128 4294967296 0x15bf
refute "780M needs no override with rocm7.2" "$(envof "$S")" "HSA_OVERRIDE"
expect "780M override for Ollama" "$(envof "$S" "gfx1030 gfx1100")" "HSA_OVERRIDE_GFX_VERSION=11.0.0"

# ── Polaris: no ROCm kernels anywhere → Ollama on Vulkan ──
S="$ROOT/s5"; mkcpu "$S"; mkgpu "$S" 1 80003 128 8589934592 0x67df
expect "Polaris vulkan" "$(fn "$S" 'ollama_vulkan_needed && echo vulkan || echo rocm')" vulkan
S1="$ROOT/s1"
expect "RDNA4 ollama rocm" "$(fn "$S1" 'ollama_vulkan_needed && echo vulkan || echo rocm')" rocm

# ── no GPU at all ──
S="$ROOT/s6"; mkcpu "$S"
expect "no GPU → empty env" "$(envof "$S")x" "x"
D=$(fn "$S" 'cmd_doctor' 2>&1); expect "doctor flags missing GPU" "$D" "no ROCm-visible AMD GPU"
expect "doctor verdict problem" "$D" "problem(s)"

# ── doctor on the dGPU+iGPU tree ──
D=$(NO_COLOR=1 fn "$S1" 'cmd_doctor' 2>&1)
expect "doctor names the card" "$D" "AMD Radeon RX 9070 XT · gfx1201 · 16 GB · PyTorch ROCm: native"
expect "doctor hides iGPU" "$D" "hidden from AI apps"
expect "doctor explains pinning" "$D" "ravn pins its apps to [0]"
expect "doctor verdict ready" "$D" "Verdict: ready"
D=$(NO_COLOR=1 HSA_OVERRIDE_GFX_VERSION=10.3.0 PYTORCH_HIP_ALLOC_CONF=expandable_segments:True fn "$S1" 'cmd_doctor' 2>&1)
expect "doctor warns global override" "$D" "HSA_OVERRIDE_GFX_VERSION=10.3.0 is set globally"
expect "doctor warns expandable_segments" "$D" "PYTORCH_HIP_ALLOC_CONF contains expandable_segments"

# ── with_env sanitises the shell and lets ravn.env win ──
mkdir -p "$ROOT/home"; printf 'MIOPEN_FIND_MODE=NORMAL\n# comment\nnot a var\n' > "$ROOT/home/ravn.env"
W=$(HSA_OVERRIDE_GFX_VERSION=9.9.9 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True fn "$S1" 'with_env "$TORCH_ARCHS" env')
refute "global override stripped" "$W" "HSA_OVERRIDE_GFX_VERSION=9.9.9"
refute "expandable_segments stripped" "$W" "PYTORCH_CUDA_ALLOC_CONF"
expect "ravn.env wins" "$W" "MIOPEN_FIND_MODE=NORMAL"
refute "ravn.env junk ignored" "$W" "not a var"
rm -f "$ROOT/home/ravn.env"

# ── venv damage detection (what a stray 'pip install torch' leaves behind) ──
V="$ROOT/venv"; SP="$V/lib/python3.12/site-packages"; mkdir -p "$SP/torch-2.14.1+rocm7.2.dist-info"
expect "clean venv" "$(fn / "venv_problems '$V'")x" "x"
mkdir -p "$SP/triton-3.7.1.dist-info"
expect "plain triton" "$(fn / "venv_problems '$V'")" plain-triton
rm -rf "$SP/torch-2.14.1+rocm7.2.dist-info"; mkdir -p "$SP/torch-2.14.1.dist-info" "$SP/nvidia_cublas_cu12-12.8.4.1.dist-info"
P=$(fn / "venv_problems '$V'")
expect "CUDA torch" "$P" "torch-not-rocm:torch-2.14.1"
expect "nvidia wheels" "$P" cuda-wheels
expect "missing venv" "$(fn / "venv_problems '$ROOT/nope'")" no-venv
V2="$ROOT/venv2"; SP2="$V2/lib/python3.12/site-packages"
mkdir -p "$SP2/torch-2.14.1+rocm7.2.dist-info" "$SP2/triton_rocm-3.8.0.dist-info" "$SP2/triton/backends"
expect "ROCm triton files gone" "$(fn / "venv_problems '$V2'")" triton-missing
touch "$SP2/triton/__init__.py"
refute "ROCm triton intact" "$(fn / "venv_problems '$V2'")" triton-missing
# a system/user-site python is checked where torch actually lives, not as a venv
expect "user site checked directly" "$(fn / "sp_problems '$SP'")" "torch-not-rocm:torch-2.14.1"

# ── overrides file blocks the clobbering packages ──
O=$(fn / 'cat "$(write_overrides)"')
expect "override drops triton" "$O" "triton ; sys_platform == 'never'"
expect "override drops onnxruntime-gpu" "$O" "onnxruntime-gpu ; sys_platform == 'never'"

# ── enable refuses when the port is taken (sandboxed: fake systemctl/curl, private config dir) ──
FB="$ROOT/fakebin"; mkdir -p "$FB" "$ROOT/h2/ollama"
printf '#!/bin/sh\nexit 3\n' > "$FB/systemctl"; printf '#!/bin/sh\nexit 0\n' > "$FB/curl"; chmod +x "$FB"/*
echo "version=v0" > "$ROOT/h2/ollama/ravn.app"
O=$(PATH="$FB:$PATH" RAVN_HOME="$ROOT/h2" XDG_CONFIG_HOME="$ROOT/cfg" NO_COLOR=1 ./ravn enable ollama 2>&1)
expect "enable refuses a taken port" "$O" "another server already answers on 127.0.0.1:11434"
[[ ! -e $ROOT/cfg/systemd/user/ravn-ollama.service ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL enable wrote a unit despite the conflict"; }

# ── CLI surface ──
expect "help" "$(NO_COLOR=1 ./ravn help)" "ravn doctor"
expect "version" "$(./ravn version)" "ravn 0."
expect "unknown app rejected" "$(./ravn install blender 2>&1)" "unknown app 'blender'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL == 0 ]]
