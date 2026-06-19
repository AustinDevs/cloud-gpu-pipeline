#!/bin/bash
set -euo pipefail

# ============================================================================
# SplatWalk Job Launcher
#
# Launches an ephemeral DigitalOcean GPU droplet that turns a directory of
# images on DO Spaces into a web-viewable Gaussian splat, uploads the result
# to the CDN, and self-destructs.
#
# Usage:
#   scripts/run_job.sh --images <spaces-path> [options]
#
#   --images PATH      Images on Spaces. Accepts:
#                        datasets/myparcel/                (prefix in $DO_SPACES_BUCKET)
#                        s3://bucket/datasets/myparcel/
#                        https://nyc3.digitaloceanspaces.com/bucket/datasets/myparcel/
#                        datasets/myparcel.zip             (a zip of images also works)
#   --pipeline MODE    splat (default) or aerial
#                        splat:  ground photos, drone photos, or a mix
#                        aerial: drone-only sets; adds top-down zoom descent
#   --job-id ID        Job identifier (default: derived from images path).
#                        Output lands at demo/<job-id>/manifest.json on the CDN.
#   --iterations N     Training iterations (default 10000)
#   --max-views N      Max MASt3R views (default 24; use 16 on 20GB GPUs)
#   --image-size N     Preprocessed image size in px (default 512)
#
# Requires .env in the repo root (see .env.example).
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/.env"

# --- Parse arguments ---
IMAGES_PATH=""
PIPELINE_MODE="splat"
JOB_ID=""
TRAIN_ITERATIONS="${TRAIN_ITERATIONS:-10000}"
MAX_N_VIEWS="${MAX_N_VIEWS:-24}"
IMAGE_SIZE="${IMAGE_SIZE:-512}"

while [ $# -gt 0 ]; do
    case "$1" in
        --images)     IMAGES_PATH="$2"; shift 2 ;;
        --pipeline)   PIPELINE_MODE="$2"; shift 2 ;;
        --job-id)     JOB_ID="$2"; shift 2 ;;
        --iterations) TRAIN_ITERATIONS="$2"; shift 2 ;;
        --max-views)  MAX_N_VIEWS="$2"; shift 2 ;;
        --image-size) IMAGE_SIZE="$2"; shift 2 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

if [ -z "$IMAGES_PATH" ]; then
    echo "Error: --images is required (a directory of images on Spaces)"
    echo "Example: scripts/run_job.sh --images datasets/myparcel/"
    exit 1
fi

case "$PIPELINE_MODE" in
    splat|aerial) ;;
    *) echo "Error: --pipeline must be 'splat' or 'aerial'"; exit 1 ;;
esac

# Normalize images path to a bucket-relative key/prefix
IMAGES_KEY="$IMAGES_PATH"
IMAGES_KEY="${IMAGES_KEY#"$DO_SPACES_ENDPOINT"/}"
IMAGES_KEY="${IMAGES_KEY#s3://}"
IMAGES_KEY="${IMAGES_KEY#"$DO_SPACES_BUCKET"/}"
IMAGES_KEY="${IMAGES_KEY%/}"

# Default job ID from the last path component (sanitized)
if [ -z "$JOB_ID" ]; then
    JOB_ID=$(basename "$IMAGES_KEY" .zip | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')
fi

echo "=== SplatWalk Job Launcher ==="
echo "Images:    s3://${DO_SPACES_BUCKET}/${IMAGES_KEY}"
echo "Pipeline:  $PIPELINE_MODE"
echo "Job ID:    $JOB_ID"
echo "Region:    ${GPU_DROPLET_REGION}"
echo "Size:      ${GPU_DROPLET_SIZE}"
echo ""

# --- Check for existing GPU droplets (DO has a 1 GPU limit) ---
echo "Checking for existing GPU droplets..."
EXISTING=$(curl -s -H "Authorization: Bearer $DO_API_TOKEN" \
    "https://api.digitalocean.com/v2/droplets?per_page=50" \
    | python3 -c "
import sys, json
for d in json.load(sys.stdin).get('droplets', []):
    if d['name'].startswith('splatwalk-gpu') or 'gpu' in d.get('size_slug', ''):
        print(f\"{d['id']} {d['name']} {d['status']}\")
" 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
    echo "Found existing GPU droplets:"
    echo "$EXISTING"
    echo ""
    read -p "Destroy existing droplets before creating new one? [y/N] " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        echo "$EXISTING" | while read -r DROPLET_ID REST; do
            echo "Destroying droplet $DROPLET_ID ($REST)..."
            curl -s -X DELETE \
                -H "Authorization: Bearer $DO_API_TOKEN" \
                "https://api.digitalocean.com/v2/droplets/$DROPLET_ID"
        done
        echo "Waiting 10s for cleanup..."
        sleep 10
    else
        echo "Aborting."
        exit 1
    fi
fi

# --- Build cloud-init script ---
CLOUD_INIT=$(cat <<'CLOUD_INIT_EOF'
#!/bin/bash
exec > /var/log/splatwalk-job.log 2>&1
set -x

echo "=== SplatWalk Job Runner ==="
echo "Job: __JOB_ID__"
echo "Pipeline: __PIPELINE_MODE__"
echo "Started: $(date -u)"

export CONDA_AUTO_ACCEPT_CHANNEL_NOTICES=true

# --- Slack helper ---
notify_slack() {
  local message="$1"
  local status="${2:-info}"
  if [ -z "__SLACK_WEBHOOK_URL__" ]; then return; fi
  local emoji=":arrows_counterclockwise:"
  [ "$status" = "success" ] && emoji=":white_check_mark:"
  [ "$status" = "error" ] && emoji=":x:"
  local payload="{\"text\":\"${emoji} *[__JOB_ID__] launcher* -- ${message}\"}"
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "__SLACK_WEBHOOK_URL__" > /dev/null 2>&1 &
}

# --- Upload boot log to Spaces (raw S3 PUT; conda/awscli may not be up yet) ---
upload_log() {
  local log_key="jobs/__JOB_ID__/logs/cloud-init.log"
  local date_str=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
  local content_type="text/plain"
  local acl="public-read"
  local resource="/__SPACES_BUCKET__/$log_key"
  local string_to_sign="PUT\n\n${content_type}\n${date_str}\nx-amz-acl:${acl}\n${resource}"
  local signature=$(echo -en "$string_to_sign" | openssl dgst -sha1 -hmac "__SPACES_SECRET__" -binary | base64)
  curl -s -X PUT \
    -H "Date: $date_str" \
    -H "Content-Type: $content_type" \
    -H "x-amz-acl: $acl" \
    -H "Authorization: AWS __SPACES_KEY__:$signature" \
    --data-binary @/var/log/splatwalk-job.log \
    "__SPACES_ENDPOINT__/__SPACES_BUCKET__/$log_key" || true
  notify_slack "Log: __SPACES_ENDPOINT__/__SPACES_BUCKET__/$log_key"
}

# --- Self-destruct trap --- ALWAYS destroys droplet on exit (success or failure)
PIPELINE_SUCCESS=false
self_destruct() {
  echo "EXIT trap fired (success=$PIPELINE_SUCCESS)..."
  upload_log
  if [ "$PIPELINE_SUCCESS" = "true" ]; then
    notify_slack "Job complete. Self-destructing." "success"
  else
    notify_slack "Job FAILED. Uploading logs + self-destructing." "error"
  fi
  sleep 2
  umount /mnt/splatwalk 2>/dev/null || true
  DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)
  curl -s -X POST \
    -H "Authorization: Bearer __DO_API_TOKEN__" \
    -H "Content-Type: application/json" \
    -d '{"type":"detach","droplet_id":'$DROPLET_ID'}' \
    "https://api.digitalocean.com/v2/volumes/__DO_VOLUME_ID__/actions"
  sleep 10
  curl -s -X DELETE \
    -H "Authorization: Bearer __DO_API_TOKEN__" \
    "https://api.digitalocean.com/v2/droplets/$DROPLET_ID"
}
trap self_destruct EXIT

# Safety timeout: 3 hours
( sleep 10800; echo "Safety timeout (3h)..."; notify_slack "Safety timeout (3h) reached." "error"; kill -9 $$ 2>/dev/null ) &

notify_slack "Droplet booted, waiting for GPU driver..."

# --- Wait for GPU ---
for i in $(seq 1 30); do
  nvidia-smi && break
  echo "Waiting for GPU... (attempt $i)"
  sleep 10
done

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
notify_slack "GPU ready: $GPU_NAME. Attaching Volume..."

# --- Attach + mount Volume ---
DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)
curl -s -X POST \
  -H "Authorization: Bearer __DO_API_TOKEN__" \
  -H "Content-Type: application/json" \
  -d '{"type":"attach","droplet_id":'$DROPLET_ID'}' \
  "https://api.digitalocean.com/v2/volumes/__DO_VOLUME_ID__/actions"

for i in $(seq 1 30); do
  ls /dev/disk/by-id/scsi-0DO_Volume_splatwalk-* 2>/dev/null && break
  echo "Waiting for Volume... (attempt $i)"
  sleep 5
done

mkdir -p /mnt/splatwalk
VOLUME_DEV=$(ls /dev/disk/by-id/scsi-0DO_Volume_splatwalk-* 2>/dev/null | head -1)
if [ -z "$VOLUME_DEV" ]; then
  echo "ERROR: Volume device not found after 30 attempts"
  notify_slack "Volume device never appeared" "error"
  exit 1
fi
mount -o discard,defaults,noatime "$VOLUME_DEV" /mnt/splatwalk || {
  echo "ERROR: mount failed, trying mkfs first..."
  mkfs.ext4 -F "$VOLUME_DEV"
  mount -o discard,defaults,noatime "$VOLUME_DEV" /mnt/splatwalk || {
    notify_slack "Volume mount FAILED even after mkfs" "error"
    exit 1
  }
}
echo "Volume mounted at /mnt/splatwalk (dev=$VOLUME_DEV)"
df -h /mnt/splatwalk

# --- Run setup if volume is empty/new ---
if ! /mnt/splatwalk/conda/bin/python --version > /dev/null 2>&1; then
  notify_slack "Fresh volume detected — running setup (~30 min)..."
  curl -fsSL -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/AustinDevs/splatwalk/contents/scripts/setup-volume.sh" \
    -o /tmp/setup-volume.sh 2>/dev/null \
    || curl -fsSL "__SPACES_ENDPOINT__/__SPACES_BUCKET__/scripts/setup-volume.sh" \
    -o /tmp/setup-volume.sh
  bash /tmp/setup-volume.sh || { notify_slack "Volume setup FAILED" "error"; exit 1; }
  notify_slack "Volume setup complete!"
fi

export PATH="/mnt/splatwalk/conda/bin:$PATH"

# Verify torch + CUDA
/mnt/splatwalk/conda/bin/python -c "
import torch
print(f'torch={torch.__version__} cuda={torch.cuda.is_available()}')
assert torch.cuda.is_available()
" || { notify_slack "CUDA not available on droplet" "error"; exit 1; }

# --- Spaces credentials ---
export SPACES_KEY=__SPACES_KEY__
export SPACES_SECRET=__SPACES_SECRET__
export SPACES_BUCKET=__SPACES_BUCKET__
export SPACES_REGION=__SPACES_REGION__
export SPACES_ENDPOINT=__SPACES_ENDPOINT__
export AWS_ACCESS_KEY_ID=$SPACES_KEY
export AWS_SECRET_ACCESS_KEY=$SPACES_SECRET
export AWS_DEFAULT_REGION=$SPACES_REGION

# --- Download input images from Spaces ---
notify_slack "Downloading images from s3://__SPACES_BUCKET__/__IMAGES_KEY__ ..."
INPUT_DIR=/workspace/__JOB_ID__/input
mkdir -p "$INPUT_DIR"

if [[ "__IMAGES_KEY__" == *.zip ]]; then
  aws s3 cp "s3://__SPACES_BUCKET__/__IMAGES_KEY__" /workspace/__JOB_ID__/dataset.zip \
    --endpoint-url "__SPACES_ENDPOINT__"
  apt-get install -y unzip 2>/dev/null || true
  unzip -q -o /workspace/__JOB_ID__/dataset.zip -d "$INPUT_DIR"
  rm /workspace/__JOB_ID__/dataset.zip
else
  aws s3 sync "s3://__SPACES_BUCKET__/__IMAGES_KEY__/" "$INPUT_DIR/" \
    --endpoint-url "__SPACES_ENDPOINT__" \
    --exclude "*" \
    --include "*.jpg" --include "*.JPG" \
    --include "*.jpeg" --include "*.JPEG" \
    --include "*.png" --include "*.PNG" \
    --include "*.mov" --include "*.MOV" \
    --include "*.mp4" --include "*.MP4"
fi

# Flatten nested directories (zip archives and prefixes may nest images/)
find "$INPUT_DIR" -mindepth 2 -type f \
  \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.mov" -o -iname "*.mp4" \) \
  -exec mv -n {} "$INPUT_DIR/" \;
find "$INPUT_DIR" -type d -empty -delete 2>/dev/null || true

NUM_IMAGES=$(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | wc -l)
echo "Input: $NUM_IMAGES images"
if [ "$NUM_IMAGES" -lt 2 ] && ! ls "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.mp4 2>/dev/null; then
  notify_slack "Only $NUM_IMAGES images found at s3://__SPACES_BUCKET__/__IMAGES_KEY__ — need at least 2" "error"
  exit 1
fi
notify_slack "Input ready ($NUM_IMAGES images). Starting __PIPELINE_MODE__ pipeline..."

# --- Fetch orchestrator from GitHub (Python scripts are fetched inside it) ---
mkdir -p /mnt/splatwalk/scripts
_CURL_ARGS=(-fsSL -H "Accept: application/vnd.github.raw")
[ -n "__GITHUB_TOKEN__" ] && _CURL_ARGS+=(-H "Authorization: token __GITHUB_TOKEN__")
if curl "${_CURL_ARGS[@]}" \
    "https://api.github.com/repos/AustinDevs/splatwalk/contents/scripts/gpu/run_pipeline.sh" \
    -o /mnt/splatwalk/scripts/run_pipeline.sh 2>/dev/null; then
  echo "Updated run_pipeline.sh (from GitHub)"
fi
chmod +x /mnt/splatwalk/scripts/run_pipeline.sh

# --- Run pipeline ---
export INPUT_DIR
export OUTPUT_DIR=/workspace/__JOB_ID__/output
export JOB_ID=__JOB_ID__
export PIPELINE_MODE=__PIPELINE_MODE__
export MAX_N_VIEWS=__MAX_N_VIEWS__
export TRAIN_ITERATIONS=__TRAIN_ITERATIONS__
export IMAGE_SIZE=__IMAGE_SIZE__
export GITHUB_TOKEN=__GITHUB_TOKEN__
export SLACK_WEBHOOK_URL='__SLACK_WEBHOOK_URL__'

PIPELINE_LOG="/workspace/__JOB_ID__/pipeline.log"
bash /mnt/splatwalk/scripts/run_pipeline.sh 2>&1 | tee "$PIPELINE_LOG"
PIPELINE_EXIT=${PIPESTATUS[0]}

# Upload pipeline log for debugging (before self-destruct)
aws s3 cp "$PIPELINE_LOG" "s3://$SPACES_BUCKET/jobs/__JOB_ID__/logs/pipeline.log" \
    --endpoint-url "$SPACES_ENDPOINT" --acl public-read --content-type "text/plain" 2>/dev/null || true

if [ "$PIPELINE_EXIT" -ne 0 ]; then
  notify_slack "Pipeline failed (exit $PIPELINE_EXIT). Log: __SPACES_ENDPOINT__/__SPACES_BUCKET__/jobs/__JOB_ID__/logs/pipeline.log" "error"
  exit 1
fi

notify_slack "Done! View at: https://splatwalk.austindevs.com/?manifest=__SPACES_ENDPOINT__/__SPACES_BUCKET__/demo/__JOB_ID__/manifest.json" "success"
echo "=== JOB COMPLETE ==="
PIPELINE_SUCCESS=true
# EXIT trap fires -> self_destruct
CLOUD_INIT_EOF
)

# --- Substitute variables into cloud-init ---
CLOUD_INIT="${CLOUD_INIT//__JOB_ID__/$JOB_ID}"
CLOUD_INIT="${CLOUD_INIT//__IMAGES_KEY__/$IMAGES_KEY}"
CLOUD_INIT="${CLOUD_INIT//__PIPELINE_MODE__/$PIPELINE_MODE}"
CLOUD_INIT="${CLOUD_INIT//__MAX_N_VIEWS__/$MAX_N_VIEWS}"
CLOUD_INIT="${CLOUD_INIT//__TRAIN_ITERATIONS__/$TRAIN_ITERATIONS}"
CLOUD_INIT="${CLOUD_INIT//__IMAGE_SIZE__/$IMAGE_SIZE}"
CLOUD_INIT="${CLOUD_INIT//__DO_API_TOKEN__/$DO_API_TOKEN}"
CLOUD_INIT="${CLOUD_INIT//__DO_VOLUME_ID__/$DO_VOLUME_ID}"
CLOUD_INIT="${CLOUD_INIT//__SPACES_KEY__/$DO_SPACES_KEY}"
CLOUD_INIT="${CLOUD_INIT//__SPACES_SECRET__/$DO_SPACES_SECRET}"
CLOUD_INIT="${CLOUD_INIT//__SPACES_BUCKET__/$DO_SPACES_BUCKET}"
CLOUD_INIT="${CLOUD_INIT//__SPACES_REGION__/$DO_SPACES_REGION}"
CLOUD_INIT="${CLOUD_INIT//__SPACES_ENDPOINT__/$DO_SPACES_ENDPOINT}"
CLOUD_INIT="${CLOUD_INIT//__SLACK_WEBHOOK_URL__/${SLACK_WEBHOOK_URL:-}}"
CLOUD_INIT="${CLOUD_INIT//__GITHUB_TOKEN__/${GHCR_TOKEN:-}}"

# --- Create the droplet ---
echo "Creating GPU droplet..."

CLOUD_INIT_FILE=$(mktemp)
echo "$CLOUD_INIT" > "$CLOUD_INIT_FILE"

PAYLOAD_FILE=$(mktemp)
python3 -c "
import json
with open('$CLOUD_INIT_FILE') as f:
    cloud_init = f.read()
payload = {
    'name': 'splatwalk-gpu-${JOB_ID:0:16}',
    'region': '${GPU_DROPLET_REGION}',
    'size': '${GPU_DROPLET_SIZE}',
    'image': '${GPU_DROPLET_IMAGE}',
    'ssh_keys': ['${DO_SSH_KEY_ID}'],
    'user_data': cloud_init,
    'monitoring': True,
}
with open('$PAYLOAD_FILE', 'w') as f:
    json.dump(payload, f)
"
rm "$CLOUD_INIT_FILE"

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $DO_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "@$PAYLOAD_FILE" \
    "https://api.digitalocean.com/v2/droplets")
rm "$PAYLOAD_FILE"

DROPLET_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['droplet']['id'])" 2>/dev/null)

if [ -z "$DROPLET_ID" ]; then
    echo "ERROR: Failed to create droplet"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    exit 1
fi

echo ""
echo "=========================================="
echo "Droplet created: $DROPLET_ID"
echo "Job ID:          $JOB_ID"
echo "Pipeline:        $PIPELINE_MODE"
echo "=========================================="
echo ""
echo "The droplet will:"
echo "  1. Attach the runtime Volume (auto-installs on first run)"
echo "  2. Sync images from s3://${DO_SPACES_BUCKET}/${IMAGES_KEY}"
echo "  3. MASt3R geometry init + InstantSplat training"
if [ "$PIPELINE_MODE" = "aerial" ]; then
echo "  4. Top-down progressive zoom descent"
echo "  5. Compress to .splat + upload manifest to CDN, then self-destruct"
else
echo "  4. Compress to .splat + upload manifest to CDN, then self-destruct"
fi
echo ""
echo "Monitor progress via Slack or check logs:"
echo "  ${DO_SPACES_ENDPOINT}/${DO_SPACES_BUCKET}/jobs/${JOB_ID}/logs/cloud-init.log"
echo "  ${DO_SPACES_ENDPOINT}/${DO_SPACES_BUCKET}/jobs/${JOB_ID}/logs/pipeline.log"
echo ""
echo "When complete, view at:"
echo "  http://localhost:3000/?manifest=${DO_SPACES_ENDPOINT}/${DO_SPACES_BUCKET}/demo/${JOB_ID}/manifest.json"
echo ""

# --- Wait for droplet to become active ---
echo "Waiting for droplet to become active..."
for i in $(seq 1 60); do
    STATUS=$(curl -s -H "Authorization: Bearer $DO_API_TOKEN" \
        "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
        | python3 -c "import sys,json; d=json.load(sys.stdin)['droplet']; ip=[n['ip_address'] for n in d['networks']['v4'] if n['type']=='public']; print(f\"{d['status']} {ip[0] if ip else 'no-ip'}\")" 2>/dev/null)
    echo "  [$i] $STATUS"
    if echo "$STATUS" | grep -q "^active"; then
        IP=$(echo "$STATUS" | awk '{print $2}')
        echo ""
        echo "Droplet active at: $IP"
        echo "SSH: ssh root@$IP"
        echo "Logs: ssh root@$IP tail -f /var/log/splatwalk-job.log"
        break
    fi
    sleep 5
done

echo ""
echo "Launcher done. Droplet is running autonomously."
echo "It will self-destruct when finished."
