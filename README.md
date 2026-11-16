<p align="center">
  <img src="macos/AppIcon.iconset/icon_256x256.png" width="128" height="128" alt="Curio app icon">
</p>

<h1 align="center">Curio</h1>

A native macOS app for curating your images: browse any folder, find a picture by describing it, and clear out duplicates. Search runs on your Mac's GPU, works offline once its model is downloaded, and your photos never leave your Mac.

## Download

Requires an Apple Silicon Mac with macOS 14 or later.

1. Download `Curio-<version>-arm64.dmg` from the [latest release](https://github.com/ElectricGoal/image-searching-macos/releases/latest).
2. Open it and drag **Curio** to **Applications**.
3. Open the app. It is not yet notarised by Apple, so the first time macOS will refuse: go to **System Settings › Privacy & Security**, scroll to the message about Curio, and choose **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/Curio.app` once.)

The app itself is about 6 MB. On first launch Curio asks which search model to download — **MobileCLIP-S4** (recommended, about 890 MB) or the lighter **CLIP ViT-B/32** (about 300 MB) — from [huggingface.co/ElectricGoal/curio-models](https://huggingface.co/ElectricGoal/curio-models). Each file is checked against its checksum. You can browse right away and choose **Not Now** to download later; after that, Curio needs no network.

## Features

### Browse

- **Open a folder** with ⌘O, from the **Recent** list, or by dropping it on the window or the Dock icon. Subfolders are included.
- Shows JPEG, PNG, HEIC, WebP, TIFF, BMP and GIF. Sort by name, date or size, and resize thumbnails from the toolbar.
- Browsing needs no index and no model: it works straight away.

### Search by meaning

- **Describe what you want** — "a quiet beach at sunset", "receipts", "dog on a sofa" — and results update as you type.
- **Search by example**: click the image button, drop an image onto the window, or choose **Find Similar** on any photo.
- **Combine an image with words**: after searching by example, type to steer the results — "at night", or "-people" to leave people out. Separate several with commas.
- Searches take milliseconds once the model is loaded. Esc returns to the full library.

### Tags and smart albums

- **Auto-tags**: Curio tags every indexed photo (beach, food, dogs, sunset, night…) on its own. The folder's most common tags appear under the search bar; click one to see only those photos. A photo's tags also show in the viewer.
- **Smart albums**: save a search with **Save as Album**, or click **+** next to Albums in the sidebar and describe what to collect ("receipts", "my dog at the beach"). Albums fill themselves and stay current as new photos are indexed. Removing an album never touches the photos.

### Clean up clutter

- **Clean Up** gathers likely clutter: screenshots, memes, documents and receipts, whiteboards, blurry shots, dark or blank frames and accidental shots.
- Nothing is selected for you. Click the images you want gone, or **Select All** for a group, then move them to the Trash in one step.

### Filter in steps

- The **Filter** page is a chain of steps, top to bottom. Each step **keeps** or **removes** the images matching a description — "portrait photos of a person", "a product on a plain white background", "a blurry, out of focus photo" — and passes the rest to the next.
- Every step shows how many images went in and how many it took out; click a step to preview what is left after it, or what it removed. **Strictness** (Loose, Balanced, Strict) sets how clearly an image must match.
- Choose a folder, or make one with **New Folder…**, and **Copy** or **Move** the result there. Nothing is overwritten: a clashing name gets a number. The chain is remembered for next time.
- Short, concrete descriptions work best. Image quality ("blurry", "artifacts") is the model's weakest area, so check those steps in the preview.
- For a step that has to be right, tick **Look at each image**. A second model, [Liquid d1-2B](https://huggingface.co/LiquidAI/d1-2B), then looks at every image reaching that step and answers it with yes or no, instead of the step being matched by description. On 83 mixed test images it kept every real "photo of people" where matching by description found 4 of 24, and it did not mistake logos and icons for "a product on a white background".
- Looking is slow — about a third of a second per image on an M4, so a few minutes per thousand — and starts only when you press **Look Now**. You can pause at any time: each answer is kept with the folder, so an image is only ever looked at once per step.

### Index once, stay current

- **Index** a folder once to make it searchable. A single progress bar shows the time left from the start.
- **Pause and resume** at any time. Work is saved as it goes, so quitting mid-index or unplugging a drive loses nothing; it picks up where it stopped.
- When images are added or changed, Curio says how many are not searchable yet. **Update Index** (⌘U) reads only those.
- Files that cannot be opened are noted once and not retried on every update.

### Find duplicates

- Finds identical files, near-identical re-saves, or similar shots.
- Marks one image per group to keep: the original rather than "copy of …", and for similar shots the **best shot**, the sharpest and best composed. Click another to keep that instead.
- Extras go to the Trash, so they can be put back.

### View

- Click a photo to open it. ←/→ move through the current list, double-click zooms, Space or Esc closes.
- Shows dimensions, size and date. Drag photos out to other apps.

### Models

- Uses **MobileCLIP-S4** by default for the best search quality. The lighter, faster **OpenAI CLIP ViT-B/32** is available too; download, switch or remove either in **Settings** (the gear at the right of the footer, or ⌘,).
- Settings says where each model is downloaded from, with a link to the page listing its files.
- Each folder remembers the model it was indexed with. Switching models only affects new indexes, or a **Rebuild Index** from the ⋯ menu; cancelling a rebuild keeps the old index.
- **Liquid d1-2B**, for careful filter steps, is optional: about 2.2 GB, downloaded in Settings straight from [Liquid AI's own repository](https://huggingface.co/LiquidAI/d1-2B-MLX-8bit) and checked file by file. It uses about 3.3 GB of memory while it runs and is released when idle.

### Private and lightweight

- Everything runs on your Mac's GPU, inside the app: search with Core ML, careful filter steps with MLX. No account; the network is used only to download a model.
- Search uses about 0.2–0.4 GB of memory and is ready a fraction of a second after launch.
- A clean, monochrome style that follows your Mac's light or dark appearance, or stays light or dark if you choose one in **Settings**. Everything is in one window, with no title bar.
- A footer along the bottom shows the running task with its progress and a Pause button, then the number of images, what is searchable, the model in use, and the gear for Settings.

## Where your data lives

- **Search indexes** stay with your photos: one file in each folder's hidden `.curio` directory. Delete it to remove the index; your photos are never touched. Answers from careful filter steps are kept in a second file beside it.
- **Settings and downloaded models** live in `~/Library/Application Support/Curio`.

## Troubleshooting

- **"Curio would like to access files on a removable volume"**: shown when your photos are on an external drive. Choose **Allow**. If you chose Don't Allow, turn it on under System Settings › Privacy & Security › Files and Folders.
- **The first search or index with a model is slow**: the first time a model is used, macOS prepares it for your Mac's GPU (about 25 seconds for MobileCLIP-S4 and 8 for CLIP ViT-B/32 on an M4). After that it loads in a fraction of a second.

## Build from source

Requires Apple Silicon, macOS 14 or later, Xcode 26.4 or later with its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), and [`uv`](https://docs.astral.sh/uv/).

```bash
bash scripts/convert-models.sh   # once: prepares the search models
bash scripts/launch.sh           # builds and opens dist/Curio.app
```

The build is plain `swift build`. MLX's GPU shaders are the one thing that cannot compile, so `scripts/build-mlx-shaders.sh` compiles them into `mlx.metallib`, which the build scripts place inside the app.

The decision model runs on Swift code in `macos/Sources/CurioKit/Engine/Decision`, written from [mlx-vlm](https://github.com/Blaizzy/mlx-vlm)'s implementation. To check it against that reference, download Liquid d1-2B in the app's Settings, then:

```bash
bash scripts/d1-reference.sh     # writes the reference's tokens, tensors and answers
bash scripts/check.sh            # the tests compare the Swift model with them
```

## License

MIT. MobileCLIP-S4's weights are published by Apple under its own [research licence](https://huggingface.co/apple/MobileCLIP-S4); Curio downloads it from a public copy, so read that licence before using or redistributing it.

Liquid d1-2B is published by Liquid AI under the [LFM Open License v1.0](https://huggingface.co/LiquidAI/d1-2B/blob/main/LICENSE), which does not license commercial use by an organisation with annual revenue of $10 million or more. Curio downloads it from Liquid AI and keeps the licence file with it. The code that runs it is adapted from mlx-vlm (Apache-2.0) and from the reference code shipped with the model.
