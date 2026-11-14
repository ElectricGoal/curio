# ImageSearch for macOS

A native macOS app for browsing your images and searching them by meaning. It is one self-contained program: the search engine is written in Swift and runs on the Apple GPU through Core ML, with no Python and no helper process.

## Download

Requires an Apple Silicon Mac with macOS 14 or later.

1. Download `ImageSearch-<version>-arm64.dmg` from the [latest release](https://github.com/ElectricGoal/image-searching-macos/releases/latest).
2. Open it and drag **ImageSearch** to **Applications**.
3. Open the app. It is not yet notarised by Apple, so the first time macOS will refuse: go to **System Settings › Privacy & Security**, scroll to the message about ImageSearch, and choose **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/ImageSearch.app` once.)

The download is about 265 MB and needs nothing else installed. Its search model (OpenAI CLIP ViT-B/32) is inside the app, so it works offline from the first launch. Settings live in `~/Library/Application Support/ImageSearch`. Your photos never leave your Mac.

## Run from source

Requires Apple Silicon, macOS 14 or later, Xcode Command Line Tools (`xcode-select --install`), and `uv` for the one-time model conversion.

```bash
bash scripts/convert-models.sh   # once: converts the search models to Core ML
bash scripts/launch.sh
```

`convert-models.sh` downloads the source weights from Hugging Face (about 2.4 GB for both models; name one to convert only that, e.g. `convert-models.sh clip-vit-b32`) and writes Core ML versions to `models/coreml/`. It runs in a throwaway environment that `uv` creates; nothing Python is needed after that.

The launcher builds `dist/ImageSearch.app`. You can open that app from Finder afterward. The app is linked to this checkout, which is where it finds its models; keep the repository in place, and rebuild after moving it. This is a local, ad-hoc signed app, not a notarized standalone distribution.

### Using the app

- **Open a folder** with ⌘O, from the **Recent** list, by dropping it on the window or the Dock icon, or with `open -a dist/ImageSearch.app ~/Pictures`. Browsing needs no model and no index. Sort by name, date or size and resize thumbnails from the toolbar.
- **Index** the folder once to make it searchable. One bar runs from 0 to 100% across scanning, loading the model, indexing and saving, with the time left shown from the start. The estimate uses how long the model took to load and how fast it indexed on this Mac last time (remembered in `.runtime/timings.json`), then switches to the current run's speed. **Pause** keeps everything indexed so far and **Resume** continues from there; each batch of images is saved as it is finished, so quitting mid-index is safe. If the drive holding the folder is unplugged part-way, indexing stops and says so, and picks up where it was next time.
- **Search** by typing a description — results update as you type — or by example: click the image button, drop an image onto the window, or choose **Find Similar** on any photo. The model stays loaded between searches, so only the first search after launch waits for it. Esc returns to the full library.
- **Stay current.** When images are added or changed, the app says how many are not searchable yet; **Update Index** (⌘U) reads only those. Files that cannot be decoded are counted once and not retried on every update. A folder indexed by a version before 0.3 says it needs a new index and rebuilds it in one click.
- **View** a photo by clicking it. ←/→ move through the current list, double-click zooms, and Space or Esc closes. The viewer shows dimensions, size and date, and photos can be dragged out to other apps.
- **Duplicates** lists identical files, near-identical re-saves, or similar shots. One image per group is marked to keep (the original rather than “copy of …”); click another to keep that instead. Extras go to the Trash, so they can be put back.
- **Models** shows the models this copy of the app has and what each is good for, and lets you select one. When the app was built with a download address, other models can be downloaded (with byte-level progress, verified by checksum) and removed again. Each folder remembers the model it was indexed with; selecting a different one only matters for new indexes, or when you choose **Rebuild Index** from the ⋯ menu. A folder indexed with a model that has since been removed says so and offers a rebuild. Cancelling a rebuild keeps the previous index.

### Look

The interface follows Minimalism & Swiss Style: monochrome surfaces and type, a single accent, square corners, hairlines in place of shadows, flush-left layout on one spacing scale. It follows the system's light or dark appearance; the photo viewer is always dark. Colours are defined once in `macos/Sources/LumaKit/Palette.swift`, where their contrast is unit-tested, and the spacing, type and control styles in `macos/Sources/Luma/Theme.swift`. Hover feedback is skipped when Reduce Motion is on.

### Where things live

In a source checkout, converted models live in `models/coreml/`, the source weights they were made from in `models/huggingface/`, and caches (including Core ML's compiled copy of each model) in `.cache/`. Build products are in `macos/.build` and `dist/`. The downloaded app keeps its settings, caches and any downloaded models under `~/Library/Application Support/ImageSearch`.

Search indexes stay with the photos: one file, `index.sqlite`, in each folder’s hidden `.imgsearch/` directory. Removing a model never touches your photos or their indexes.

### How it is built

The interface is SwiftUI (`macos/Sources/Luma`) on top of a UI-free core (`macos/Sources/LumaKit`). The search engine is part of that core (`LumaKit/Engine`) and runs inside the app:

- **Models** run through Core ML with float16 weights on the GPU. `scripts/convert-models.sh` converts them from PyTorch — the only step that uses Python, and only on the machine that builds the app. The conversion also records PyTorch's outputs for reference inputs, and the Swift tests check the tokenizer and both encoders against them.
- **Images** are decoded with ImageIO: upright (EXIF rotation applied), colour-managed to sRGB, transparent areas on white — what you see when you open the file.
- **The index** is one SQLite file per folder. An image's vector is stored in the same row as its metadata, so an interrupted run never leaves the two out of step, and a rebuild is written beside the old index and swapped in whole.
- **Search and duplicate detection** are exact (no approximation), using Accelerate.

The engine is a Swift actor behind the `SearchEngine` protocol, and inference sits behind `EmbeddingModel`, so another runtime — Apple's Core AI on macOS 27, for instance — can be added without touching indexing or search. Progress reports carry the task's overall position (`fraction`), the seconds remaining (`eta`) and how far the bar may advance before the next report (`ceiling`), so the bar keeps moving smoothly without running ahead of the work. The model stays in memory between searches, which is what makes repeat searches take milliseconds; after ten idle minutes its memory is released.

The app defaults to MobileCLIP-S4 for search quality and also offers the lighter OpenAI CLIP ViT-B/32. Their licences differ: CLIP ViT-B/32 is MIT, while Apple publishes the MobileCLIP-S4 weights under its own [research licence](https://huggingface.co/apple/MobileCLIP-S4). That is why the release build carries ViT-B/32 only unless you opt in (below); read the licence before distributing MobileCLIP-S4 with the app.

### Releasing

```bash
bash scripts/build-dmg.sh      # dist/ImageSearch-<version>-arm64.dmg
bash scripts/check-dmg.sh      # mounts it, copies the app out, indexes and searches with it
```

`build-dmg.sh` assembles a self-contained app — the Swift binary and the Core ML models it should carry — runs the app's own self-test (`ImageSearch --self-test` indexes and searches a few generated images with every model inside it), then compresses it into a disk image. Unlike `launch.sh`, the result does not depend on this checkout. The version comes from `macos/VERSION`, or `APP_VERSION`.

| Variable | Effect |
|---|---|
| `BUNDLE_MODELS` | Models to put inside the app. Default `clip-vit-b32` (263 MB image). `BUNDLE_MODELS="mobileclip-s4 clip-vit-b32"` adds MobileCLIP-S4 (about 1 GB more) — see the licence note above. |
| `MODELS_URL` | An address serving the contents of `models/coreml/` (any static host). The app can then download models it does not carry; each file is checked against the SHA-256 in that model's `files.json`. |
| `CODESIGN_IDENTITY`, `NOTARY_PROFILE` | Sign with a Developer ID and notarise (below). |

Pushing a tag such as `v0.3.0` runs `.github/workflows/release.yml`, which converts the bundled model, runs the tests, builds the image, checks it and attaches it to a GitHub release. To publish by hand instead: `gh release create v0.3.0 dist/ImageSearch-0.3.0-arm64.dmg --generate-notes`.

By default the app is ad-hoc signed, which is why users must confirm opening it. With an Apple Developer ID, set `CODESIGN_IDENTITY` (and `NOTARY_PROFILE`, a `notarytool` keychain profile) and the script signs the app with the hardened runtime, notarises the image and staples the ticket, so it opens without a warning.

### Verifying

```bash
bash scripts/check.sh          # Swift tests, release build, signature, the app's self-test
bash scripts/check.sh --e2e    # also drives the app's real state against the real default model
```

The end-to-end run opens a sample folder, indexes it, searches by text and by image, checks that the results are relevant, reviews duplicates and moves one to the Trash. Set `LUMA_SNAPSHOT_DIR` to keep a rendered screenshot of each step. When the command-line tool's environment is set up (`scripts/setup.sh`), `check.sh` runs its Python tests too.

## Command-line tool

The CLI below is a separate Python program for scripting; the app does not use it. It keeps its own index format (FAISS), so index a given folder with the app or with the CLI, not both — the app treats a CLI index as one that needs rebuilding. Both skip hidden files and folders (names starting with a dot). Set it up with `bash scripts/setup.sh`, then `bash -c 'source scripts/env.sh; .venv/bin/imgsearch --help'`.


Semantic image search CLI for macOS, accelerated by the Apple GPU.

Search a folder of images using **either text or another image** as the query. Embeddings are computed once using [MobileCLIP-S4](https://huggingface.co/apple/MobileCLIP-S4) (default) or [CLIP ViT-B/32](https://huggingface.co/openai/clip-vit-base-patch32), stored in a hidden `.imgsearch/` directory next to your photos, and searched with FAISS.

## Requirements

- macOS 13.5+
- Apple Silicon (M1/M2/M3/M4)
- Python 3.11 or 3.12
- 16 GB RAM recommended for the default model (about 4.3 GB in use); on 8 GB, choose `clip-vit-b32` (about 1.7 GB)

## Install

### From PyPI (recommended for now)

```bash
pipx install imgsearch
```

After install, add support for **MobileCLIP-S4** (the default model):

```bash
pip install "mobileclip @ git+https://github.com/apple/ml-mobileclip.git"
```

> MobileCLIP is distributed as a git package with non-standard build metadata, so it is listed as an optional dependency rather than bundled in the main install. `clip-vit-b32` works without this step.

### From Homebrew (once the tap is published)

```bash
brew tap toxu/imgsearch
brew install imgsearch
```

## Usage

### Index a folder

```bash
imgsearch index ~/Pictures
```

First run downloads the model weights into the HuggingFace cache (about 1.8 GB for MobileCLIP-S4, 600 MB for CLIP ViT-B/32). Re-running only re-embeds files whose contents changed.

Progress is shown with a live bar:

```
imgsearch indexing /Users/you/Pictures with MobileCLIP-S4 (Apple)
Scanning files...
  found 1024 image files
  plan: +1024 new/changed, ~0 mtime-only, -0 removed, 0 unchanged
Loading model (first run downloads weights)...
  model ready in 2.1s
⠋ embedding ━━━━━━━━━━━━━━━━━━━━━━━━━━ 1024/1024  0:00:46
✓ indexed 1024 images in 46.2s (22.2 img/s)
```

### Search by text

```bash
imgsearch search ~/Pictures --text "a dog on a beach"
```

### Search by example image

```bash
imgsearch search ~/Pictures --image ~/Desktop/reference.jpg -k 5
```

### JSON output (for scripting)

```bash
imgsearch search ~/Pictures -t "sunset" --json | jq '.[0].path'
```

### Find and remove duplicate images

```bash
# Dry run — show duplicate groups, no files changed (default)
imgsearch dedup ~/Pictures

# Stricter threshold (default 0.98, range 0.5–1.0)
imgsearch dedup ~/Pictures --threshold 0.995

# Only find exact byte-for-byte duplicates (SHA-1), no embedding comparison
imgsearch dedup ~/Pictures --exact-only

# Move duplicates to a quarantine folder (safer than delete)
imgsearch dedup ~/Pictures --move-to ~/Desktop/duplicates --no-dry-run

# Delete duplicates, keep the largest file, skip confirmation
imgsearch dedup ~/Pictures --delete --keep largest --force
```

Two levels of detection — no model reload required:

- **Exact**: SHA-1 hash match (same file, different name/location) — instant, zero false positives
- **Similar**: cosine similarity on stored embeddings (same scene, different compression/crop) — no model reload needed

Keep strategies: `largest` (default), `newest`, `oldest`, `highest-res`.

Example output:

```
Found 3 duplicate group(s) — 5 redundant image(s)

Group 1 — exact (SHA-1)
  ✓ KEEP  /Users/you/Pictures/IMG_1234.jpg     3.2 MB
    DUP   /Users/you/Downloads/copy.jpg        3.2 MB

Group 2 — similar (cosine 0.994)
  ✓ KEEP  /Users/you/Pictures/sunset.heic      5.8 MB
    DUP   /Users/you/Desktop/sunset_edit.jpg   1.1 MB
    DUP   /Users/you/Desktop/sunset_small.png  412 KB
```

### Inspect / clean

```bash
imgsearch status ~/Pictures
imgsearch clean ~/Pictures        # removes the .imgsearch/ directory
```

## How it works

1. `scanner.py` walks the folder, collecting supported image files and their mtimes.
2. `index.plan()` compares mtime (fast path) then SHA-1 (slow path) against the existing metadata DB and decides what to re-embed.
3. The embedder (MobileCLIP via open_clip, or CLIP via Transformers, both on PyTorch with the Apple GPU) returns L2-normalized float32 vectors.
4. `VectorStore` wraps a FAISS `IndexIDMap2(IndexFlatIP)` — exact brute-force cosine search, no training, crash-safe atomic writes.
5. `MetaStore` is a small SQLite database holding the mapping from FAISS id to file path, plus hashes and mtimes.

On 1,000 images on an M2 16GB laptop, indexing takes ~45s and search latency is sub-millisecond.

## Supported models

For the command-line tool (the app's own figures are under [Backend selection](#backend-selection)):

| Alias | HuggingFace id | Dim | Backend | Peak memory | Indexing speed |
|---|---|---|---|---|---|
| `mobileclip-s4` *(default)* | `apple/MobileCLIP-S4` | 768 | open_clip on PyTorch MPS | 4.3 GB | 24 img/s |
| `clip-vit-b32` | `openai/clip-vit-base-patch32` | 512 | Transformers on PyTorch MPS | 1.7 GB | 125 img/s |

Measured on an Apple M4 while indexing in batches of 8. MobileCLIP-S4 gives the better search results and is the default; its memory use is tight on an 8 GB Mac, where `clip-vit-b32` is the comfortable choice. Change with `imgsearch index <folder> --model clip-vit-b32`, or in the app's Models page. Once indexed, the manifest remembers the model id so later searches use the same one.

The MLX backend and the models that depended on it were removed: SigLIP SO400M (384 and 224), SigLIP2 Base 8-bit (it failed on the first image batch inside `mlx-embeddings`) and CLIP ViT-L/14. A folder indexed with one of these says it needs a rebuild.

## Troubleshooting

- **"Index was built with model X"**: you're searching with a different model than you indexed with. Either pass `--model X` to match or `imgsearch clean <folder>` and re-index.
- **Out of memory on 8 GB**: pass `--batch 4` to `index`.
- **HEIC files fail**: make sure `pillow-heif` installed cleanly. It ships wheels for macOS arm64.
- **"ImageSearch would like to access files on a removable volume"**: shown when your photos (or, for a source build, this checkout) are on an external drive. Choose **Allow**. Until you do, browsing works but the app says macOS is blocking access to the drive; if you chose Don't Allow, turn it on under System Settings › Privacy & Security › Files and Folders. Rebuilding the app can make macOS ask again.
- **The first search or index with a model is slow**: Core ML prepares each model for this Mac's GPU the first time it is used (about 25 seconds for MobileCLIP-S4 and 8 for CLIP ViT-B/32 on an M4) and keeps the result. After that a model loads in a fraction of a second.
- **"This folder needs a new index"**: its index was made by a version before 0.3 or by the command-line tool. Choose **Rebuild Index**; your photos are not touched.

## Development

This project uses [uv](https://github.com/astral-sh/uv) for dependency and environment management.

```bash
# One-time setup: create venv and install all deps (including dev group)
uv sync

# Run the CLI
uv run imgsearch --help

# Run tests
uv run pytest -q

# Add a new dependency
uv add <package>
uv add --dev <package>

# Upgrade lockfile
uv lock --upgrade
```

The project pins Python 3.11 via `.python-version`. `uv sync` will download a matching interpreter automatically if you don't have one. The lockfile (`uv.lock`) is committed so builds are reproducible.

## License

MIT

## Backend selection

The app's engine is Swift on Core ML; the Python backend (PyTorch/MPS with FAISS) remains only as the command-line tool. Measured on an Apple M4 with a folder of 84 mixed images (photos, screenshots, icons; one undecodable) and 16 text queries, each backend running its whole pipeline — decode, resize, embed:

| | App: Swift, Core ML float16, GPU | CLI: Python, PyTorch MPS |
|---|---|---|
| **MobileCLIP-S4** — ready after launch | 0.2 s | 11 s |
| indexing | 33 images/s | 22 images/s |
| text query | 8 ms | 31–35 ms |
| peak memory (process footprint) | 0.2–0.4 GB | 4.3 GB |
| **CLIP ViT-B/32** — ready after launch | 0.1 s | 25–28 s |
| indexing | 97 images/s | 115 images/s |
| text query | 4 ms | 11–34 ms |
| peak memory (process footprint) | 0.2–0.3 GB | 1.9 GB |

The first time a model is used, Core ML spends about 25 s (MobileCLIP-S4) or 8 s (ViT-B/32) preparing it for the GPU; the figures above are for every launch after that. ViT-B/32 indexing is the one figure where Python is ahead — probably because it runs the model on eight images at a time, where the app runs them one by one.

**Do they return the same results?** Given identical pixels, yes: the float16 Core ML models on the GPU ranked every query's top 10 exactly as PyTorch did (image embedding cosine ≥ 0.9995). Restricted to the Neural Engine the same models were faster still but agreed with PyTorch on only 75–81% of top results, so the app uses the GPU only. (That may be what the earlier benchmark in `docs/benchmark-results/` saw when it recorded that float16 changed retrieval results.)

End to end, the app and the CLI do differ on some files, by design: the app draws transparent images on white and applies EXIF rotation, where the CLI drops the alpha channel (usually leaving black) and ignores rotation. On this folder the embeddings of ordinary photos agreed closely (cosine ≥ 0.991 for every image at least 64 px across), while transparent PNGs and tiny icons moved, taking top-10 overlap between the two down to 79%. With transparency handled the same way in both, top-1 agreed on 15 of 16 queries and top-10 overlap was 92.5%; the rest is very small icons being enlarged by different filters.

Apple's Core AI (macOS 27) was also tried with the same models: it loaded faster and used less memory but indexed more slowly (28 images/s), and it needs macOS 27, so it is not used yet.

These figures are in [swift-engine.json](docs/benchmark-results/swift-engine.json). The earlier [benchmark results](docs/benchmark-results/comparison-summary.json), [float32 results](docs/benchmark-results/comparison-float32-summary.json), and [selection decision](docs/benchmark-results/backend-selection.json) are kept for reference; they compared inference alone and predate the Swift engine.
