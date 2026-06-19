#!/bin/bash
set -e
export PATH="/mnt/splatwalk/conda/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
shopt -s nocaseglob  # case-insensitive globbing (matches .JPG, .jpg, .Jpg, etc.)

# ============================================================================
# SplatWalk GPU Pipeline Orchestrator
#
# Runs on the GPU droplet. Takes a directory of images (ground-level photos,
# drone photos, or a mix) and produces a web-viewable .splat + manifest on
# DO Spaces.
#
# Pipeline modes (PIPELINE_MODE):
#   splat   (default) Images -> MASt3R geometry -> InstantSplat training ->
#           prune/compress -> .splat + manifest on CDN.
#           Works for ground-level photo sets, drone sets, or mixed.
#   aerial  Same as splat, plus the top-down progressive zoom descent
#           (render + retrain at 5 altitude levels). Only useful when the
#           input is predominantly nadir drone imagery.
#
# Required environment variables:
#   INPUT_DIR      Directory containing input images (or a video file)
#   OUTPUT_DIR     Directory for output files
#   JOB_ID         Job identifier (used in CDN paths: demo/$JOB_ID/...)
#   SPACES_KEY / SPACES_SECRET / SPACES_BUCKET / SPACES_REGION / SPACES_ENDPOINT
#
# Optional:
#   PIPELINE_MODE        splat (default) or aerial
#   SLACK_WEBHOOK_URL    Slack incoming webhook for progress notifications
#   MAX_N_VIEWS          Max views for MASt3R (default 24; use 16 on 20GB GPUs)
#   TRAIN_ITERATIONS     Stage 2 training iterations (default 10000)
#   IMAGE_SIZE           Preprocessed image size in px (default 512)
#   SCENE_SCALE          Uniform viewer scale (default 50.0)
#   PRUNE_RATIO          Fraction of Gaussians pruned at compression (default 0.20)
#   DESCENT_ALTITUDES    Aerial mode altitude fractions (default 1.0,0.5,0.25,0.12,0.05)
#   DESCENT_ITERATIONS   Aerial mode retrain iterations per level (default 2000)
# ============================================================================

PIPELINE_MODE="${PIPELINE_MODE:-splat}"

# --- Fetch latest Python scripts from GitHub (allows hotfixes without rebuilding the volume) ---
echo "Updating pipeline scripts from GitHub..."
_CURL_ARGS=(-fsSL -H "Accept: application/vnd.github.raw")
[ -n "$GITHUB_TOKEN" ] && _CURL_ARGS+=(-H "Authorization: token $GITHUB_TOKEN")
_BASE_URL="https://api.github.com/repos/AustinDevs/splatwalk/contents/scripts/gpu"
for _script in render_zoom_descent.py compress_splat.py generate_viewer_assets.py; do
    if curl "${_CURL_ARGS[@]}" "$_BASE_URL/$_script" -o "/mnt/splatwalk/scripts/$_script" 2>/dev/null; then
        echo "  Updated $_script"
    else
        echo "  Using baked-in $_script (fetch failed)"
    fi
done

echo "=========================================="
echo "SplatWalk GPU Pipeline"
echo "=========================================="
echo "Pipeline: $PIPELINE_MODE"
echo "Job ID: $JOB_ID"
echo "Input: $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
echo "=========================================="

# --- Slack notification helper ---
notify_slack() {
    local message="$1"
    local status="${2:-info}"  # info, success, error

    if [ -z "$SLACK_WEBHOOK_URL" ]; then return; fi

    local emoji=":arrows_counterclockwise:"
    [ "$status" = "success" ] && emoji=":white_check_mark:"
    [ "$status" = "error" ] && emoji=":x:"

    local payload="{\"text\":\"${emoji} *[${JOB_ID:0:8}] ${PIPELINE_MODE}* -- ${message}\"}"
    curl -s -X POST -H 'Content-type: application/json' \
        --data "$payload" "$SLACK_WEBHOOK_URL" > /dev/null 2>&1 &
}

# Validate required environment variables
if [ -z "$INPUT_DIR" ] || [ -z "$OUTPUT_DIR" ] || [ -z "$JOB_ID" ]; then
    echo "Error: Missing required environment variables"
    echo "Required: INPUT_DIR, OUTPUT_DIR, JOB_ID"
    exit 1
fi

if [ -z "$SPACES_KEY" ] || [ -z "$SPACES_SECRET" ] || [ -z "$SPACES_BUCKET" ]; then
    echo "Error: Missing Spaces credentials"
    exit 1
fi

case "$PIPELINE_MODE" in
    splat|aerial) ;;
    *)
        echo "Error: Unknown pipeline mode: $PIPELINE_MODE (expected: splat, aerial)"
        exit 1
        ;;
esac

mkdir -p "$OUTPUT_DIR"

# Configure AWS CLI for DO Spaces
export AWS_ACCESS_KEY_ID="$SPACES_KEY"
export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET"
export AWS_DEFAULT_REGION="$SPACES_REGION"

fail() {
    notify_slack "$1" "error"
    echo "FATAL: $1"
    exit 1
}

# ============================================================================
# Stage 0: Input preparation
# ============================================================================

# Video input: extract frames at 1 fps
VIDEO_FILE=$(ls -1 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.mp4 2>/dev/null | head -1)
if [ -n "$VIDEO_FILE" ]; then
    echo "Found video input: $VIDEO_FILE — extracting frames at 1 fps..."
    FRAMES_DIR="$INPUT_DIR/frames"
    mkdir -p "$FRAMES_DIR"
    ffmpeg -i "$VIDEO_FILE" -qscale:v 1 -vf "fps=1" "$FRAMES_DIR/frame-%04d.jpg" 2>&1
    export INPUT_DIR="$FRAMES_DIR"
fi

IMAGE_COUNT=$(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | wc -l | tr -d ' ')
echo "Found $IMAGE_COUNT input images"
if [ "$IMAGE_COUNT" -lt 2 ]; then
    fail "Need at least 2 input images (found $IMAGE_COUNT)"
fi
notify_slack "Starting $PIPELINE_MODE pipeline with $IMAGE_COUNT images"

# Preprocess: resize all images to a consistent square size.
# InstantSplat requires every image in a scene to have identical dimensions,
# and the input may mix landscape ground shots with portrait/drone frames.
# Strategy: scale so the short side hits IMAGE_SIZE, then center-crop.
SCENE_DIR="$OUTPUT_DIR/scene"
mkdir -p "$SCENE_DIR/images"
export SCENE_DIR
export IMAGE_SIZE="${IMAGE_SIZE:-512}"

echo "Preprocessing images to ${IMAGE_SIZE}x${IMAGE_SIZE}..."
python3 << 'PREPROCESS_SCRIPT'
import os
import sys
from PIL import Image, ImageOps
from pathlib import Path

input_dir = os.environ["INPUT_DIR"]
output_dir = os.path.join(os.environ["SCENE_DIR"], "images")
size = int(os.environ.get("IMAGE_SIZE", "512"))
target = (size, size)

os.makedirs(output_dir, exist_ok=True)

for img_file in sorted(Path(input_dir).glob("*")):
    if img_file.suffix.lower() not in (".jpg", ".jpeg", ".png"):
        continue
    try:
        img = Image.open(img_file)
        img = ImageOps.exif_transpose(img).convert("RGB")  # respect EXIF orientation
        w, h = img.size
        scale = max(target[0] / w, target[1] / h)
        new_w, new_h = int(w * scale), int(h * scale)
        img = img.resize((new_w, new_h), Image.LANCZOS)
        left = (new_w - target[0]) // 2
        top = (new_h - target[1]) // 2
        img = img.crop((left, top, left + target[0], top + target[1]))
        img.save(os.path.join(output_dir, img_file.stem + ".jpg"), "JPEG", quality=95)
        print(f"  Processed: {img_file.name} -> {target[0]}x{target[1]}")
    except Exception as e:
        print(f"  Error processing {img_file.name}: {e}", file=sys.stderr)
PREPROCESS_SCRIPT

NUM_IMAGES=$(ls -1 "$SCENE_DIR/images" | wc -l | tr -d ' ')
echo "Prepared $NUM_IMAGES images (${IMAGE_SIZE}x${IMAGE_SIZE})"
[ "$NUM_IMAGES" -lt 2 ] && fail "Preprocessing produced fewer than 2 usable images"

# Cap views for MASt3R memory (pairwise matching is O(n^2) in VRAM)
MAX_VIEWS="${MAX_N_VIEWS:-24}"
N_VIEWS=$NUM_IMAGES
[ "$N_VIEWS" -gt "$MAX_VIEWS" ] && N_VIEWS=$MAX_VIEWS
TRAIN_ITERS="${TRAIN_ITERATIONS:-10000}"

# ============================================================================
# Stage 1: MASt3R geometry initialization (point cloud + camera poses)
# ============================================================================

cd /mnt/splatwalk/InstantSplat

notify_slack "Stage 1: Geometry init (MASt3R, $N_VIEWS views)..."
echo "Stage 1: Running geometry initialization with MASt3R ($N_VIEWS views)..."
python init_geo.py \
    --source_path "$SCENE_DIR" \
    --model_path "$OUTPUT_DIR/model" \
    --n_views "$N_VIEWS" \
    --focal_avg \
    --co_vis_dsp \
    --conf_aware_ranking \
    2>&1 || fail "Stage 1 (init_geo.py) failed"
notify_slack "Stage 1 complete: point cloud + camera poses"

# ============================================================================
# Stage 2: InstantSplat training (3DGS with pose optimization)
# ============================================================================

notify_slack "Stage 2: Training splat ($TRAIN_ITERS iterations)..."
echo "Stage 2: Training Gaussian Splatting ($TRAIN_ITERS iterations)..."
python train.py \
    --source_path "$SCENE_DIR" \
    --model_path "$OUTPUT_DIR/model" \
    --iterations "$TRAIN_ITERS" \
    --n_views "$N_VIEWS" \
    --pp_optimizer \
    --optim_pose \
    || fail "Stage 2 (train.py) failed"
notify_slack "Stage 2 complete: splat trained"

FINAL_MODEL_PATH="$OUTPUT_DIR/model"
DRONE_AGL=""

# ============================================================================
# Stage 3 (aerial mode only): Top-down progressive zoom descent
# ============================================================================

if [ "$PIPELINE_MODE" = "aerial" ]; then
    # Estimate drone AGL from EXIF GPS altitude + ground elevation (open-meteo)
    echo "Extracting EXIF GPS altitude for descent scaling..."
    DRONE_AGL=$(python3 -c "
import sys, json, urllib.request
from pathlib import Path
from PIL import Image, ExifTags
try:
    for f in sorted(Path('$INPUT_DIR').glob('*')):
        if f.suffix.lower() not in ('.jpg', '.jpeg', '.png'):
            continue
        exif = Image.open(f)._getexif()
        if not exif:
            continue
        gps = exif.get(ExifTags.Base.GPSInfo)
        if not gps:
            continue
        tags = {ExifTags.GPSTAGS.get(k, k): v for k, v in gps.items()}
        if 'GPSLatitude' not in tags or 'GPSAltitude' not in tags:
            continue
        def dms(d, r):
            v = float(d[0]) + float(d[1]) / 60 + float(d[2]) / 3600
            return -v if r in ('S', 'W') else v
        lat = dms(tags['GPSLatitude'], tags.get('GPSLatitudeRef', 'N'))
        lon = dms(tags['GPSLongitude'], tags.get('GPSLongitudeRef', 'W'))
        alt = float(tags['GPSAltitude'])
        if alt <= 0:
            continue
        url = f'https://api.open-meteo.com/v1/elevation?latitude={lat}&longitude={lon}'
        elev = json.loads(urllib.request.urlopen(url, timeout=5).read()).get('elevation', 0)
        if isinstance(elev, list):
            elev = elev[0]
        print(f'{max(10, alt - elev):.0f}')
        break
except Exception as e:
    print(f'EXIF AGL extraction failed: {e}', file=sys.stderr)
" 2>/dev/null) || true
    echo "Drone AGL: ${DRONE_AGL:-unknown (using descent default)}"

    notify_slack "Stage 3: Top-down zoom descent..."
    echo "Stage 3: Top-down progressive zoom descent..."
    DESCENT_ARGS=(
        --model_path "$OUTPUT_DIR/model"
        --scene_path "$SCENE_DIR"
        --output_dir "$OUTPUT_DIR/descent"
        --altitudes "${DESCENT_ALTITUDES:-1.0,0.5,0.25,0.12,0.05}"
        --retrain_iterations "${DESCENT_ITERATIONS:-2000}"
        --max_images_per_level 64
        --slack_webhook_url "${SLACK_WEBHOOK_URL:-}"
        --job_id "$JOB_ID"
    )
    [ -n "$DRONE_AGL" ] && DESCENT_ARGS+=(--drone_agl "$DRONE_AGL")

    python /mnt/splatwalk/scripts/render_zoom_descent.py "${DESCENT_ARGS[@]}" \
        || fail "Stage 3 (render_zoom_descent.py) failed"
    notify_slack "Stage 3 complete: zoom descent finished"

    FINAL_MODEL_PATH="$OUTPUT_DIR/descent/final"
fi

# ============================================================================
# Stage 4: Compress to .splat + manifest + CDN upload
# ============================================================================

notify_slack "Stage 4: Compressing splat + uploading to CDN..."
echo "Stage 4: Compressing splat + generating viewer assets..."
ASSET_ARGS=(
    --model_path "$FINAL_MODEL_PATH"
    --output_dir "$OUTPUT_DIR/demo"
    --job_id "$JOB_ID"
    --scene_scale "${SCENE_SCALE:-50.0}"
    --prune_ratio "${PRUNE_RATIO:-0.20}"
    --source_images "$IMAGE_COUNT"
    --slack_webhook_url "${SLACK_WEBHOOK_URL:-}"
)
[ -n "$DRONE_AGL" ] && ASSET_ARGS+=(--drone_agl "$DRONE_AGL")

python /mnt/splatwalk/scripts/generate_viewer_assets.py "${ASSET_ARGS[@]}" \
    || fail "Stage 4 (generate_viewer_assets.py) failed"

notify_slack "Pipeline complete! Manifest: $SPACES_ENDPOINT/$SPACES_BUCKET/demo/$JOB_ID/manifest.json" "success"
echo "Pipeline $PIPELINE_MODE completed successfully!"
exit 0
