#!/usr/bin/env python3
"""
Generate Viewer Assets: .splat + manifest.json on the CDN

Takes a trained InstantSplat model directory and produces everything the web
viewer needs:
  1. Prune + compress the latest PLY checkpoint to .splat (via compress_splat.py)
  2. Compute scene bounds from the PLY (same centroid + uniform scale transform
     that compress_splat.py applies, so bounds match the .splat coordinates)
  3. Write manifest.json with camera defaults and upload both to DO Spaces

Manifest format:
  {
    "splat_url": "https://cdn.../scene.splat",
    "viewer_mode": "splat",
    "viewer_modes": ["topdown", "walk"],
    "scene_bounds": { "min": [...], "max": [...], "center": [...],
                      "size": [...], "ground_z": ... },
    "camera_defaults": { "position": [...], "look_at": [...], "up": [...] },
    "walk_camera_defaults": { "position": [...], "look_at": [...], "up": [...] },
    "metadata": { "scene_scale": 50.0, "splat_size_mb": ..., ... }
  }

Usage:
    python generate_viewer_assets.py \
        --model_path /workspace/job/output/model \
        --output_dir /workspace/job/output/demo \
        --job_id myparcel
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np


# ---------------------------------------------------------------------------
# CDN upload
# ---------------------------------------------------------------------------

def upload_to_cdn(local_path, remote_key):
    """Upload a file to DO Spaces. Returns the public URL."""
    endpoint = os.environ.get("SPACES_ENDPOINT", "")
    bucket = os.environ.get("SPACES_BUCKET", "")

    if not endpoint or not bucket:
        print(f"  SKIP upload (no Spaces credentials): {local_path}")
        return f"file://{os.path.abspath(local_path)}"

    content_types = {
        ".splat": "application/octet-stream",
        ".json": "application/json",
        ".jpg": "image/jpeg",
        ".png": "image/png",
    }
    content_type = content_types.get(Path(local_path).suffix.lower(),
                                     "application/octet-stream")

    cmd = [
        "aws", "s3", "cp", local_path,
        f"s3://{bucket}/{remote_key}",
        "--endpoint-url", endpoint,
        "--acl", "public-read",
        "--content-type", content_type,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Upload failed: {result.stderr[:200]}")
        return f"file://{os.path.abspath(local_path)}"

    url = f"{endpoint}/{bucket}/{remote_key}"
    print(f"  Uploaded: {remote_key}")
    return url


def notify_slack(message, webhook_url, job_id, status="info"):
    """Non-blocking Slack notification."""
    if not webhook_url:
        return
    import urllib.request
    emoji = {"info": "\U0001f504", "success": "✅", "error": "❌"}.get(status, "\U0001f504")
    payload = json.dumps({"text": f"{emoji} *[{job_id[:8]}] assets* — {message}"})
    try:
        req = urllib.request.Request(
            webhook_url,
            data=payload.encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Scene bounds + compression
# ---------------------------------------------------------------------------

def find_latest_ply(model_path):
    """Find the highest-iteration point_cloud.ply checkpoint."""
    ckpt_dirs = sorted(
        Path(model_path).glob("point_cloud/iteration_*"),
        key=lambda p: int(p.name.split("_")[-1]),
    )
    if not ckpt_dirs:
        raise FileNotFoundError(f"No checkpoints in {model_path}")
    ply_path = ckpt_dirs[-1] / "point_cloud.ply"
    if not ply_path.exists():
        raise FileNotFoundError(f"Missing point_cloud.ply in {ckpt_dirs[-1]}")
    return str(ply_path)


def compute_scene_bounds(ply_path, scene_scale=50.0):
    """Compute viewer-space scene bounds from the PLY.

    Mirrors compress_splat.py's transform: center at centroid, multiply by
    scene_scale. Bounds use 1st/99th percentiles so stray floaters don't
    inflate the camera start altitude.
    """
    try:
        from plyfile import PlyData
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "plyfile"])
        from plyfile import PlyData

    ply_data = PlyData.read(ply_path)
    vertex = ply_data["vertex"]

    positions = np.stack([
        np.array(vertex["x"], dtype=np.float32),
        np.array(vertex["y"], dtype=np.float32),
        np.array(vertex["z"], dtype=np.float32),
    ], axis=-1)

    centroid = positions.mean(axis=0)
    scaled = (positions - centroid) * scene_scale

    lo = np.percentile(scaled, 1, axis=0)
    hi = np.percentile(scaled, 99, axis=0)
    ground_z = float(np.percentile(scaled[:, 2], 5))

    return {
        "min": [float(v) for v in lo],
        "max": [float(v) for v in hi],
        "center": [float(v) for v in (lo + hi) / 2],
        "size": [float(v) for v in hi - lo],
        "ground_z": ground_z,
    }


def compress_splat(ply_path, output_splat, prune_ratio=0.20, scene_scale=50.0):
    """Invoke compress_splat.py to create the .splat file."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "compress_splat.py")
    cmd = [
        sys.executable, script,
        ply_path, output_splat,
        "--prune_ratio", str(prune_ratio),
        "--scene_scale", str(scene_scale),
    ]
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"compress_splat.py failed with code {result.returncode}")
    print(f"  Compressed splat: {output_splat}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate viewer assets (.splat + manifest)")
    parser.add_argument("--model_path", required=True,
                        help="Trained model directory (contains point_cloud/iteration_*)")
    parser.add_argument("--output_dir", required=True, help="Local output directory")
    parser.add_argument("--job_id", required=True, help="Job ID for CDN paths (demo/<job_id>/)")
    parser.add_argument("--scene_scale", type=float, default=50.0, help="Uniform scene scale")
    parser.add_argument("--prune_ratio", type=float, default=0.20, help="Splat prune ratio")
    parser.add_argument("--drone_agl", type=float, default=None,
                        help="Drone AGL in meters (aerial mode metadata)")
    parser.add_argument("--source_images", type=int, default=None,
                        help="Number of source images (metadata)")
    parser.add_argument("--slack_webhook_url", default="")
    args = parser.parse_args()

    if not args.slack_webhook_url:
        args.slack_webhook_url = os.environ.get("SLACK_WEBHOOK_URL", "")

    os.makedirs(args.output_dir, exist_ok=True)
    remote_prefix = f"demo/{args.job_id}"

    # --- Compress ---
    ply_path = find_latest_ply(args.model_path)
    print(f"Using checkpoint: {ply_path}")

    splat_path = os.path.join(args.output_dir, "scene.splat")
    compress_splat(ply_path, splat_path,
                   prune_ratio=args.prune_ratio, scene_scale=args.scene_scale)
    splat_size_mb = Path(splat_path).stat().st_size / 1024 / 1024

    # --- Bounds ---
    bounds = compute_scene_bounds(ply_path, args.scene_scale)
    print(f"  Scene bounds:")
    print(f"    X: [{bounds['min'][0]:.1f}, {bounds['max'][0]:.1f}]")
    print(f"    Y: [{bounds['min'][1]:.1f}, {bounds['max'][1]:.1f}]")
    print(f"    Z: [{bounds['min'][2]:.1f}, {bounds['max'][2]:.1f}]")
    print(f"    Ground Z: {bounds['ground_z']:.1f}")

    # --- Upload splat ---
    notify_slack(f"Uploading scene.splat ({splat_size_mb:.1f}MB)...",
                 args.slack_webhook_url, args.job_id)
    splat_url = upload_to_cdn(splat_path, f"{remote_prefix}/scene.splat")

    # --- Manifest ---
    scene_height = bounds["max"][2] - bounds["min"][2]
    viewing_altitude = float(bounds["max"][2] + scene_height * 0.5)
    ground_z = bounds["ground_z"]
    cx, cy = bounds["center"][0], bounds["center"][1]

    metadata = {
        "scene_scale": args.scene_scale,
        "splat_size_mb": round(splat_size_mb, 1),
    }
    if args.drone_agl is not None:
        metadata["drone_agl_m"] = args.drone_agl
    if args.source_images is not None:
        metadata["source_images"] = args.source_images

    manifest = {
        "splat_url": splat_url,
        "viewer_mode": "splat",
        "viewer_modes": ["topdown", "walk"],
        "scene_bounds": bounds,
        "camera_defaults": {
            "position": [cx, cy, viewing_altitude],
            "look_at": [cx, cy, ground_z],
            "up": [0.0, 1.0, 0.0],
        },
        "walk_camera_defaults": {
            "position": [cx, cy, ground_z + 2.0],
            "look_at": [cx + 5.0, cy, ground_z + 2.0],
            "up": [0.0, 0.0, 1.0],
        },
        "metadata": metadata,
    }

    manifest_path = os.path.join(args.output_dir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    manifest_url = upload_to_cdn(manifest_path, f"{remote_prefix}/manifest.json")

    notify_slack(
        f"Assets complete! {splat_size_mb:.1f}MB splat, "
        f"scene {bounds['size'][0]:.0f}x{bounds['size'][1]:.0f} units. "
        f"Manifest: {manifest_url}",
        args.slack_webhook_url, args.job_id, "success",
    )

    print(f"\nDone. Manifest: {json.dumps(manifest, indent=2)}")


if __name__ == "__main__":
    main()
