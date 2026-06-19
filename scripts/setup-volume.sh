#!/bin/bash
set -euo pipefail
#
# Setup script for the SplatWalk runtime Volume.
#
# Installs the full pipeline runtime onto a DO Volume at /mnt/splatwalk/:
#   Miniconda + Python 3.11, PyTorch 2.4 + CUDA 12.4, InstantSplat (with its
#   compiled CUDA extensions), and the MASt3R/DUSt3R model weights.
#
# INCREMENTAL: Safe to re-run on an existing Volume. Each step checks
# whether its work is already present and skips if so.
#
# Usage:
#   1. Create a 100GB Volume in the GPU region via DO console or API:
#        curl -s -X POST \
#          -H "Authorization: Bearer $DO_API_TOKEN" \
#          -H "Content-Type: application/json" \
#          -d '{"size_gigabytes":100,"name":"splatwalk-runtime","region":"tor1",
#               "filesystem_type":"ext4"}' \
#          "https://api.digitalocean.com/v2/volumes"
#
#   2. Create a GPU droplet in the same region and attach the Volume:
#        mount -o discard,defaults,noatime /dev/disk/by-id/scsi-0DO_Volume_splatwalk-* /mnt/splatwalk
#
#   3. Run this script:
#        bash /root/setup-volume.sh
#
#   4. When done, unmount + detach Volume, destroy the droplet.
#      The Volume persists and is reattached by pipeline droplets at runtime.
#
# Note: scripts/run_job.sh runs this automatically when it detects a fresh
# Volume, so manual setup is only needed for debugging or pre-warming.
#

VOLUME_ROOT="/mnt/splatwalk"

if [ ! -d "$VOLUME_ROOT" ]; then
    echo "ERROR: $VOLUME_ROOT does not exist. Mount the Volume first."
    echo "  mkdir -p /mnt/splatwalk"
    echo "  mount -o discard,defaults,noatime /dev/disk/by-id/scsi-0DO_Volume_splatwalk-* /mnt/splatwalk"
    exit 1
fi

echo "============================================"
echo "SplatWalk Volume Setup"
echo "Target: $VOLUME_ROOT"
echo "============================================"

# --- Step 1: Verify GPU ---
echo ""
echo "=== Step 1/7: Verify GPU ==="
if ! nvidia-smi; then
    echo "ERROR: No NVIDIA GPU detected. This script must run on a GPU droplet."
    exit 1
fi
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
echo "GPU: $GPU_NAME"

# --- Step 2: System packages ---
echo ""
echo "=== Step 2/7: System packages ==="
if command -v ffmpeg &>/dev/null && command -v git &>/dev/null && dpkg -s build-essential &>/dev/null 2>&1; then
    echo "System packages already installed — skipping"
else
    echo "Installing system packages..."
    apt-get update -qq
    apt-get install -y -qq \
        git wget curl ffmpeg unzip pkg-config \
        libgl1-mesa-glx libglib2.0-0 build-essential
    apt-get clean
    rm -rf /var/lib/apt/lists/*
fi

# --- Step 3: Miniconda + Python 3.11 ---
echo ""
echo "=== Step 3/7: Miniconda + Python 3.11 ==="
if [ -x "$VOLUME_ROOT/conda/bin/python" ]; then
    echo "Miniconda already installed on Volume"
else
    echo "Installing Miniconda to $VOLUME_ROOT/conda..."
    wget -q -O /tmp/miniconda.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
    bash /tmp/miniconda.sh -b -p "$VOLUME_ROOT/conda"
    rm /tmp/miniconda.sh
fi
export PATH="$VOLUME_ROOT/conda/bin:$PATH"
# Accept Conda TOS (required since Conda 25.x) — env var is most reliable
export CONDA_AUTO_ACCEPT_CHANNEL_NOTICES=true
conda config --set auto_accept_channel_notices true 2>/dev/null || true
# Pin Python 3.11 to match PyTorch 2.4 compatibility (3.13 is too new)
PYVER=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
if [ "$PYVER" != "3.11" ]; then
    echo "Python $PYVER detected, downgrading to 3.11..."
    conda install -y python=3.11
fi
echo "Python: $(python --version 2>&1)"

# --- Step 4: PyTorch + CUDA + Python deps ---
echo ""
echo "=== Step 4/7: PyTorch + CUDA + Python packages ==="
export TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0"

if python -c "import torch; assert torch.cuda.is_available(); print(f'PyTorch {torch.__version__} CUDA OK')" 2>/dev/null; then
    echo "PyTorch with CUDA already installed — skipping"
else
    echo "Installing PyTorch 2.4 with CUDA 12.4..."
    pip install --no-cache-dir \
        torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 \
        --index-url https://download.pytorch.org/whl/cu124
fi

# Ensure build tools are available for CUDA extension compilation
pip install --no-cache-dir setuptools wheel 2>&1 | tail -1

echo "Installing runtime Python packages..."
pip install --no-cache-dir \
    "numpy<2" scipy pillow tqdm einops timm roma \
    opencv-python scikit-image matplotlib tensorboard \
    imageio imageio-ffmpeg trimesh \
    plyfile boto3 awscli huggingface_hub 2>&1 | tail -5

# --- Step 5: InstantSplat + CUDA extensions ---
echo ""
echo "=== Step 5/7: InstantSplat + CUDA extensions ==="

if [ -d "$VOLUME_ROOT/InstantSplat" ]; then
    echo "InstantSplat repo already cloned — skipping clone"
else
    echo "Cloning InstantSplat..."
    git clone --recursive https://github.com/NVlabs/InstantSplat.git "$VOLUME_ROOT/InstantSplat"
fi

# Build CUDA extensions
if python -c "import diff_gaussian_rasterization" 2>/dev/null; then
    echo "diff-gaussian-rasterization already built — skipping"
else
    echo "Building diff-gaussian-rasterization..."
    cd "$VOLUME_ROOT/InstantSplat/submodules/diff-gaussian-rasterization"
    pip install --no-cache-dir --no-build-isolation .
fi

if python -c "import simple_knn" 2>/dev/null; then
    echo "simple-knn already built — skipping"
else
    echo "Building simple-knn..."
    cd "$VOLUME_ROOT/InstantSplat/submodules/simple-knn"
    pip install --no-cache-dir --no-build-isolation .
fi

if [ -d "$VOLUME_ROOT/InstantSplat/submodules/fused-ssim" ]; then
    if python -c "import fused_ssim" 2>/dev/null; then
        echo "fused-ssim already built — skipping"
    else
        echo "Building fused-ssim..."
        cd "$VOLUME_ROOT/InstantSplat/submodules/fused-ssim"
        pip install --no-cache-dir --no-build-isolation .
    fi
fi

# Build curope extension
CUROPE_DIR="$VOLUME_ROOT/InstantSplat/croco/models/curope"
if [ -d "$CUROPE_DIR" ]; then
    if ls "$CUROPE_DIR"/*.so &>/dev/null; then
        echo "curope extension already built — skipping"
    else
        echo "Building curope extension..."
        cd "$CUROPE_DIR"
        python setup.py build_ext --inplace || true
    fi
fi

# Install InstantSplat requirements
echo "Installing InstantSplat requirements..."
cd "$VOLUME_ROOT/InstantSplat"
pip install --no-cache-dir -r requirements.txt 2>&1 | tail -3 || true

# Strip .git dirs to save space
find "$VOLUME_ROOT/InstantSplat" -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

# --- Step 6: Model weights ---
echo ""
echo "=== Step 6/7: Model weights ==="

mkdir -p "$VOLUME_ROOT/models/dust3r" "$VOLUME_ROOT/models/mast3r"

DUST3R_CKPT="$VOLUME_ROOT/models/dust3r/DUSt3R_ViTLarge_BaseDecoder_512_dpt.pth"
MAST3R_CKPT="$VOLUME_ROOT/models/mast3r/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric.pth"

if [ -f "$DUST3R_CKPT" ]; then
    echo "DUSt3R checkpoint already present — skipping"
else
    echo "Downloading DUSt3R checkpoint (~2.5GB)..."
    wget -q -O "$DUST3R_CKPT" \
        "https://download.europe.naverlabs.com/ComputerVision/DUSt3R/DUSt3R_ViTLarge_BaseDecoder_512_dpt.pth"
fi

if [ -f "$MAST3R_CKPT" ]; then
    echo "MASt3R checkpoint already present — skipping"
else
    echo "Downloading MASt3R checkpoint (~2.5GB)..."
    wget -q -O "$MAST3R_CKPT" \
        "https://download.europe.naverlabs.com/ComputerVision/MASt3R/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric.pth"
fi

# Symlink checkpoints to expected locations
mkdir -p "$VOLUME_ROOT/InstantSplat/dust3r/checkpoints" "$VOLUME_ROOT/InstantSplat/mast3r/checkpoints"
ln -sf "$DUST3R_CKPT" "$VOLUME_ROOT/InstantSplat/dust3r/checkpoints/" 2>/dev/null || true
ln -sf "$MAST3R_CKPT" "$VOLUME_ROOT/InstantSplat/mast3r/checkpoints/" 2>/dev/null || true

# Alternate lookup paths
MAST3R_ALT="$VOLUME_ROOT/InstantSplat/submodules/mast3r/checkpoints"
mkdir -p "$MAST3R_ALT"
ln -sf "$MAST3R_CKPT" "$MAST3R_ALT/" 2>/dev/null || true

# --- Step 7: Pipeline scripts + verification ---
echo ""
echo "=== Step 7/7: Pipeline scripts + verification ==="

mkdir -p "$VOLUME_ROOT/scripts"

# Copy scripts if running from a checkout (runtime droplets re-fetch from GitHub anyway)
SCRIPT_DIR=""
if [ -d "$(dirname "$0")/gpu" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")/gpu" && pwd)"
elif [ -d "/root/pipeline-scripts" ]; then
    SCRIPT_DIR="/root/pipeline-scripts"
fi

if [ -n "$SCRIPT_DIR" ]; then
    echo "Copying pipeline scripts from $SCRIPT_DIR to $VOLUME_ROOT/scripts/..."
    for script in run_pipeline.sh render_zoom_descent.py compress_splat.py generate_viewer_assets.py; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "$VOLUME_ROOT/scripts/$script"
            echo "  Copied $script"
        else
            echo "  WARNING: $script not found in $SCRIPT_DIR"
        fi
    done
    chmod +x "$VOLUME_ROOT/scripts/run_pipeline.sh" 2>/dev/null || true
else
    echo "No local scripts found — they will be fetched from GitHub at runtime."
fi

echo "Checking key imports..."
python -c "
import torch; print(f'PyTorch {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
print(f'GPU: {torch.cuda.get_device_name(0)}')
import diff_gaussian_rasterization; print('diff-gaussian-rasterization OK')
import simple_knn; print('simple-knn OK')
import plyfile; print('plyfile OK')
import boto3; print('boto3 OK')
print('All imports OK')
"

# Cleanup
echo ""
echo "Cleaning up caches..."
pip cache purge 2>/dev/null || true
rm -rf /root/.cache/pip /tmp/*

# Report disk usage
echo ""
echo "Volume disk usage:"
du -sh "$VOLUME_ROOT"/* 2>/dev/null | sort -rh
echo ""
du -sh "$VOLUME_ROOT"
echo ""

echo "============================================"
echo "Volume setup complete!"
echo "============================================"
echo ""
echo "To use this Volume with pipeline droplets:"
echo "  1. Set DO_VOLUME_ID in .env to this Volume's ID"
echo "  2. Set GPU_DROPLET_IMAGE to any stock DO GPU base image"
echo "  3. Ensure GPU_DROPLET_REGION matches the Volume's region"
echo ""
echo "To update dependencies later:"
echo "  1. Launch any GPU droplet in the same region, attach + mount this Volume"
echo "  2. export PATH=$VOLUME_ROOT/conda/bin:\$PATH"
echo "  3. pip install <package> or conda install <package>"
echo "  4. Unmount + detach Volume, destroy droplet"
echo ""
