# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

SplatWalk — a directory of photos on DO Spaces in, a web-viewable Gaussian splat out. Input can be professional ground-level photos, drone photos, or a mix. An ephemeral DigitalOcean GPU droplet runs the reconstruction pipeline (pure photogrammetry + splat training, **no AI generation**), uploads results to DO Spaces CDN, and self-destructs. A static viewer (this repo, no build step) displays the result.

See README.md for the full architecture write-up.

## Commands

```bash
npm run dev                                    # Static file server for local viewer dev
scripts/run_job.sh --images datasets/foo/      # Launch a GPU job (default: splat pipeline)
scripts/run_job.sh --images ... --pipeline aerial  # Drone-only sets: adds zoom descent
scripts/cleanup-droplets.sh                    # Destroy stale GPU droplets
```

No build step, no test suite, no linter. Pure static HTML/JS/CSS plus bash/python pipeline scripts.

## Project Structure

```
index.html              # Splat fly-over/walk viewer
js/viewer.js            # Viewer logic (Three.js + GaussianSplats3D via importmap)
css/styles.css          # Base styles
coi-serviceworker.js    # COEP/COOP service worker for crossOriginIsolated
scripts/
  run_job.sh            # Launcher: Spaces images dir → GPU droplet → splat on CDN
  setup-volume.sh       # Install runtime onto DO Volume (idempotent)
  cleanup-droplets.sh   # Destroy stale GPU droplets
  gpu/                  # Scripts that run on the remote GPU droplet
    run_pipeline.sh           # Orchestrator (PIPELINE_MODE: splat | aerial)
    render_zoom_descent.py    # Aerial mode: top-down progressive zoom descent
    compress_splat.py         # Pruning + floater removal + .splat conversion
    generate_viewer_assets.py # Compress + scene bounds + manifest + CDN upload
```

## Pipeline Stages (run_pipeline.sh)

1. **Stage 0**: Preprocess — EXIF-rotate, resize all images to uniform square (default 512px, `IMAGE_SIZE`)
2. **Stage 1**: MASt3R geometry initialization (`init_geo.py` — point cloud + camera poses)
3. **Stage 2**: InstantSplat training (default 10K iterations, `--pp_optimizer --optim_pose`)
4. **Stage 3** (aerial mode only): Top-down progressive zoom descent (`render_zoom_descent.py`)
   - 5 altitude levels: drone → 50% → 25% → 12% → 5% of drone AGL
   - All cameras nadir; pure render + retrain (2K iters/level, densification on)
   - Drone AGL estimated from EXIF GPS altitude minus open-meteo ground elevation
5. **Stage 4**: `generate_viewer_assets.py` — compress to .splat, compute bounds, write + upload manifest to `demo/<job-id>/` on Spaces

## Infrastructure

- **Everything-on-Volume**: Runtime (conda, InstantSplat, MASt3R/DUSt3R weights) lives on a persistent DO Volume at `/mnt/splatwalk/`. Droplets are stateless — attach Volume at boot, detach on self-destruct. Fresh volumes auto-provision via `setup-volume.sh`.
- Pipeline scripts are fetched from GitHub at runtime for hotfixes (repo: AustinDevs/splatwalk).
- **ALWAYS destroy GPU droplets on exit** — both success AND failure (EXIT trap + 3h safety timeout).
- DO has a **1 GPU droplet limit** — always check/destroy existing before creating new.
- GPU: RTX 6000 Ada (48GB, $1.57/hr) in tor1 recommended — RTX 4000 Ada frequently unavailable.
- Logs upload to `jobs/<job-id>/logs/` on Spaces; progress via Slack webhook.

## Critical Technical Details

### Uniform Scene Scaling (.splat format)
Positions AND scales must be multiplied by the **same factor** (default 50x). Separate scale multipliers distort trained Gaussian overlap proportions, causing wash-out or speckle. Scene is centered at centroid before scaling.

### InstantSplat Training
- `n_views` is a **path component** (`sparse_{n_views}/0/`), NOT a camera count limit
- `Scene()` always starts from COLMAP, never from checkpoints — retrains clear old checkpoints first
- Densification is disabled in Stage 2 — enabled in Stage 3 zoom descent for new detail
- All images in a scene must have identical dimensions (hence Stage 0 square crop)
- MASt3R pairwise matching is O(n²) in VRAM — `MAX_N_VIEWS` caps it (24 default, 16 on 20GB GPUs)

### Top-Down Progressive Zoom (aerial mode)
The descent stays looking straight down at all altitudes — the splat only renders well from directions it was trained on. Progressive steps let Gaussian scales adapt gradually. Only useful for nadir drone sets; never run it on ground-photo scenes.

### Web Viewer
- CDN assets require CORS headers from DO Spaces; hosting must provide COEP/COOP (coi-serviceworker.js handles GitHub Pages)
- **`gpuAcceleratedSort: false`** — GPU sort silently fails
- `computeSceneBounds()` only works for .splat files (reads binary format directly)
- GaussianSplats3D viewer options (`gpuAcceleratedSort`, `antialiased`, `kernel2DSize`, `sphericalHarmonicsDegree`) are compile-time — set at construction
- WASD moves on XY plane, Q/E adjusts altitude, mouse orbits; walk mode clamps to ground_z
- Three.js r160 + GaussianSplats3D v0.4.7 (lazy-loaded)

### Manifest Format
```json
{
  "splat_url": "https://cdn.../scene.splat",
  "viewer_mode": "splat",
  "viewer_modes": ["topdown", "walk"],
  "scene_bounds": { "min": [...], "max": [...], "center": [...], "size": [...], "ground_z": ... },
  "camera_defaults": { "position": [...], "look_at": [...], "up": [0,1,0] },
  "walk_camera_defaults": { "position": [...], "look_at": [...], "up": [0,0,1] },
  "metadata": { "scene_scale": 50, "splat_size_mb": 54, "source_images": 38 }
}
```

### Known Gotchas (fixed, don't regress)
- **Conda 25.x TOS**: `export CONDA_AUTO_ACCEPT_CHANNEL_NOTICES=true`
- **numpy float32 JSON**: cast to `float()` before `json.dump()`
- **train.py crash**: `--test_iterations 10001` workaround when retraining
- COLMAP cameras.json `rotation` = R_c2w; COLMAP wants `R_w2c = R_c2w.T`, `T_w2c = -R_w2c @ position`

## Environment

`.env` is used by `scripts/run_job.sh` (GPU launcher), not by the static site. Key variables:
- `DO_API_TOKEN`, `DO_SPACES_KEY/SECRET/BUCKET/REGION/ENDPOINT`, `DO_VOLUME_ID` — DigitalOcean infra
- `DO_SSH_KEY_ID`, `DO_SSH_PRIVATE_KEY_PATH` — SSH key for GPU droplets
- `GPU_DROPLET_SIZE/REGION/IMAGE` — droplet config
- `SLACK_WEBHOOK_URL` — pipeline progress notifications (optional)
- `GHCR_TOKEN` — GitHub token for fetching scripts if repo is private (optional)
- `MAX_N_VIEWS`, `TRAIN_ITERATIONS`, `IMAGE_SIZE` — tuning (optional)
