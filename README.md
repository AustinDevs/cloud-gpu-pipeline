# SplatWalk

Turn a directory of photos into an interactive 3D Gaussian splat you can fly
around (and walk through) in the browser.

You point the launcher at a directory of images on DigitalOcean Spaces —
professional ground-level photos, drone shots, or a mix — and it spins up an
ephemeral GPU droplet that reconstructs the scene, trains a Gaussian splat,
compresses it for the web, uploads it to the CDN, and destroys itself. The
static viewer in this repo then loads the result from a manifest URL.

There is no AI generation anywhere in the pipeline: it is pure photogrammetry
(MASt3R) plus Gaussian splat training (InstantSplat). What you photograph is
what you get.

## Quick start

```bash
# 1. One-time: copy .env.example to .env and fill in DigitalOcean credentials
cp .env.example .env

# 2. Upload your photos to Spaces
aws s3 sync ./my-photos/ s3://splatwalk/datasets/myparcel/ \
    --endpoint-url https://nyc3.digitaloceanspaces.com

# 3. Launch the job (ground photos, mixed sets — the default pipeline)
scripts/run_job.sh --images datasets/myparcel/

# For drone-only nadir sets, add the aerial refinement pass:
scripts/run_job.sh --images datasets/myparcel/ --pipeline aerial

# 4. When Slack says it's done (or ~30-50 min later), view it:
npm run dev
# open http://localhost:3000/?manifest=https://nyc3.digitaloceanspaces.com/splatwalk/demo/myparcel/manifest.json
```

`--images` accepts a bucket-relative prefix (`datasets/myparcel/`), an s3 URI,
a full https URL, or a `.zip` of images. See `scripts/run_job.sh --help` for
all flags (`--job-id`, `--iterations`, `--max-views`, `--image-size`).

## How it works

```
 Spaces: datasets/myparcel/*.jpg
        │
        ▼
 run_job.sh ──► creates GPU droplet (cloud-init)
                  │  attach runtime Volume, sync images
                  ▼
                run_pipeline.sh on the droplet
                  │
                  ├─ Stage 0  Preprocess: EXIF-rotate, resize to uniform
                  │           square (default 512px) — InstantSplat needs
                  │           identical dimensions across the set
                  ├─ Stage 1  MASt3R geometry init (init_geo.py):
                  │           dense point cloud + camera poses, no COLMAP
                  │           feature matching needed — works on sparse,
                  │           wide-baseline ground photo sets
                  ├─ Stage 2  InstantSplat training (default 10K iterations,
                  │           joint pose optimization)
                  ├─ Stage 3  [aerial mode only] Top-down progressive zoom
                  │           descent: render nadir grids at 5 altitude
                  │           levels, retrain 2K iters each (render_zoom_descent.py)
                  └─ Stage 4  Compress: importance-prune 20%, floater removal,
                              uniform 50x scene scale, 32-byte/Gaussian .splat
                              (compress_splat.py) → upload .splat + manifest
                              (generate_viewer_assets.py)
        │
        ▼
 Spaces CDN: demo/<job-id>/scene.splat + manifest.json
        │
        ▼
 index.html?manifest=...  (Three.js + GaussianSplats3D viewer)
```

### Pipelines

| Flag | What it does | Use for |
|------|--------------|---------|
| `--pipeline splat` (default) | Stages 0-2 + compress | Ground-level photo sets, mixed ground+drone, orbit captures |
| `--pipeline aerial` | Adds Stage 3 zoom descent | Predominantly nadir drone imagery where you want extra overhead detail at low altitude |

The aerial descent keeps every virtual camera pointing straight down and
re-renders/retrains at 100% → 50% → 25% → 12% → 5% of the drone's altitude.
That only makes sense when the splat was trained from overhead views, so
don't use it on ground photo sets.

### Infrastructure (everything-on-Volume)

- The runtime (Miniconda, PyTorch+CUDA, InstantSplat with compiled CUDA
  extensions, MASt3R/DUSt3R weights, ~30GB) lives on a persistent DO Volume.
- Droplets are stateless and ephemeral: stock DO GPU image, attach the Volume
  at boot, detach + **self-destruct on exit (success or failure)** via an EXIT
  trap. A 3-hour safety timeout backstops hangs.
- A fresh/empty Volume is detected at boot and provisioned automatically by
  `scripts/setup-volume.sh` (~30 min, one time).
- Pipeline scripts are fetched from GitHub at droplet boot, so hotfixes don't
  require touching the Volume.
- Logs are uploaded to `jobs/<job-id>/logs/` on Spaces before self-destruct;
  progress goes to Slack if `SLACK_WEBHOOK_URL` is set.
- DigitalOcean enforces a **1 GPU droplet limit** — the launcher checks for
  and offers to destroy existing droplets first. `scripts/cleanup-droplets.sh`
  nukes stragglers.

### Output manifest

`demo/<job-id>/manifest.json`:

```json
{
  "splat_url": "https://nyc3.digitaloceanspaces.com/splatwalk/demo/myparcel/scene.splat",
  "viewer_mode": "splat",
  "viewer_modes": ["topdown", "walk"],
  "scene_bounds": { "min": [...], "max": [...], "center": [...], "size": [...], "ground_z": -12.3 },
  "camera_defaults": { "position": [...], "look_at": [...], "up": [0, 1, 0] },
  "walk_camera_defaults": { "position": [...], "look_at": [...], "up": [0, 0, 1] },
  "metadata": { "scene_scale": 50.0, "splat_size_mb": 54.2, "source_images": 38 }
}
```

### Web viewer

Static site, no build step (`npm run dev` serves it locally). Loads the
manifest from `?manifest=<url>` (falls back to the aukerman demo).

- Fly mode: `WASD` moves on the XY plane, `Q`/`E` adjusts altitude, mouse
  orbits. Walk mode (button, top right): ground-clamped first-person.
- Needs `crossOriginIsolated` for SharedArrayBuffer — `coi-serviceworker.js`
  injects COEP/COOP headers on hosts that don't set them (e.g. GitHub Pages).
- Spaces must serve CORS headers for browser fetches of the splat.
- `gpuAcceleratedSort` stays **false** — the GPU sort path silently fails.

## Repo layout

```
index.html              Splat viewer page
js/viewer.js            Viewer logic (Three.js + GaussianSplats3D)
css/styles.css          Base styles
coi-serviceworker.js    COEP/COOP service worker for crossOriginIsolated
scripts/
  run_job.sh            Launch a job: Spaces images dir → splat on CDN
  setup-volume.sh       Provision the runtime Volume (idempotent)
  cleanup-droplets.sh   Destroy stale GPU droplets
  gpu/                  Scripts that run on the GPU droplet
    run_pipeline.sh           Orchestrator (splat / aerial modes)
    render_zoom_descent.py    Aerial-mode top-down zoom refinement
    compress_splat.py         Prune + floater removal + .splat conversion
    generate_viewer_assets.py Compress + bounds + manifest + CDN upload
```

## Cost

RTX 6000 Ada ($1.57/hr): a default `splat` job is roughly 30-40 min (~$1);
`aerial` adds ~20-30 min for the descent. The Volume costs ~$10/mo at 100GB
and is reused across all jobs.
