<p align="center">
  <img src="macos/AppIcon.iconset/icon_256x256.png" width="128" height="128" alt="Curio app icon">
</p>

<h1 align="center">Curio</h1>

A native macOS app for curating your images: browse any folder, find a picture by describing it, and clear out duplicates. Search runs on your Mac's GPU, works offline once its model is downloaded, and your photos never leave your Mac.

## Download

Requires an Apple Silicon Mac with macOS 14 or later.

Download `Curio-<version>-arm64.dmg` from the [latest release](https://github.com/ElectricGoal/curio/releases/latest). Curio is not signed with an Apple Developer ID, so macOS cannot verify it, and how you install it depends on your macOS version.

**macOS 27 and later.** Dragging Curio to Applications fails with "Could not install — This Mac could not verify the app, so nothing was installed." Install it from Terminal instead. This downloads the latest release and installs it:

```bash
curl -fsSL https://raw.githubusercontent.com/ElectricGoal/curio/main/scripts/install.sh | bash
```

Or, with a disk image you already downloaded: `bash install.sh ~/Downloads/Curio-0.0.2-arm64.dmg` ([install.sh](scripts/install.sh)). Run it again to update; it replaces the app and keeps your settings, models and indexes. To uninstall, move `/Applications/Curio.app` to the Trash.

<details><summary>By hand, without the script</summary>

```bash
hdiutil attach ~/Downloads/Curio-*-arm64.dmg
ditto /Volumes/Curio*/Curio.app /Applications/Curio.app
hdiutil detach /Volumes/Curio*
xattr -dr com.apple.quarantine /Applications/Curio.app   # clears the "downloaded from the internet" mark
open /Applications/Curio.app
```

</details>

**macOS 14 to 26.** Open the disk image and drag **Curio** to **Applications**. The first time you open it, macOS refuses: go to **System Settings › Privacy & Security**, scroll to the message about Curio, and choose **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/Curio.app` once.)

The app itself is about 6 MB. On first launch Curio asks which search model to download — **MobileCLIP-S4** (recommended, about 890 MB) or the lighter **CLIP ViT-B/32** (about 300 MB) — from [huggingface.co/ElectricGoal/curio-models](https://huggingface.co/ElectricGoal/curio-models). Each file is checked against its checksum. You can browse right away and choose **Not Now** to download later; after that, Curio needs no network.

## Features

### Albums

- An **album** is a folder of photos. Add as many as you like with **+** beside Albums in the sidebar (⌘O), several at once, or by dropping folders on the window or the Dock icon. Subfolders are included.
- Each album has four tabs: **Photos**, **Duplicates**, **Clean Up** and **Filter**. Switching albums keeps the tab you are on.
- Right-click an album to show it in Finder or remove it from Curio; removing never touches the photos. An album on a drive that is not connected stays in the list, dimmed, until the drive is back.

### Browse

- Shows JPEG, PNG, HEIC, WebP, TIFF, BMP and GIF. Sort by name, date or size, and resize thumbnails from the toolbar.
- Browsing needs no index and no model: it works straight away.

### Search by meaning

- **Describe what you want** — "a quiet beach at sunset", "receipts", "dog on a sofa" — and results update as you type.
- **Search by example**: click the image button, drop an image onto the window, or choose **Find Similar** on any photo.
- **Combine an image with words**: after searching by example, type to steer the results — "at night", or "-people" to leave people out. Separate several with commas.
- Searches take milliseconds once the model is loaded. Esc returns to the full library.

### Tags and saved searches

- **Auto-tags**: Curio tags every indexed photo (beach, food, dogs, sunset, night…) on its own. The folder's most common tags appear under the search bar; click one to see only those photos. A photo's tags also show in the viewer.
- **Saved searches**: search for something ("receipts", "my dog at the beach") and choose **Save Search**. It appears as a bookmark chip before the tags, fills itself and stays current as new photos are indexed. Right-click the chip to remove it; that never touches the photos.

### Clean up clutter

- **Clean Up** gathers likely clutter: screenshots, memes, documents and receipts, whiteboards, blurry shots, dark or blank frames and accidental shots.
- Nothing is selected for you. Click the images you want gone, or **Select All** for a group, then move them to the Trash in one step.

### Filter in steps

- The **Filter** page is a chain of steps, top to bottom. Each step **keeps** or **removes** the images matching a description — "portrait photos of a person", "a product on a plain white background", "a blurry, out of focus photo" — and passes the rest to the next.
- Every step shows how many images went in and how many it took out; click a step to preview what is left after it, or what it removed. **Strictness** (Loose, Balanced, Strict) sets how clearly an image must match.
- Choose a folder, or make one with **New Folder…**, and **Copy** or **Move** the result there. Nothing is overwritten: a clashing name gets a number. The chain is remembered for next time.
- Short, concrete descriptions work best. Image quality ("blurry", "artifacts") is the model's weakest area, so check those steps in the preview.
- Every step has a permanent number (**#1**, **#2**…) that stays the same when steps are moved, and its own **model**: matching the description against the album's search index (instant), the default decision model chosen in Settings, or a specific decision model (Liquid d1-2B or its smaller 4-bit version).
- **Trace a photo**: click any photo in the Filter preview to see its way through the chain — at each numbered step, whether it was kept, passed or removed, and why (how well it fitted the description, or how sure the model was, against what the step needs). The chain marks the same on each node, and the result says whether the photo made it.
- For a step that has to be right, choose a model that **looks at each image**. A second model, [Liquid d1-2B](https://huggingface.co/LiquidAI/d1-2B) (run from Liquid AI's MLX builds, quantized to 8 or 4 bits; see [Models](#models)), then looks at every image reaching that step and answers it with yes or no, instead of the step being matched by description. On 83 mixed test images it kept every real "photo of people" where matching by description found 4 of 24, and it did not mistake logos and icons for "a product on a white background".
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
- For careful filter steps there are two optional builds of Liquid AI's d1-2B, both in MLX format and downloaded in Settings straight from Liquid AI's repositories, each at one fixed revision and checked file by file:

  | In Settings | Exact model | Quantization | Download | Memory while running |
  |---|---|---|---|---|
  | **Liquid d1-2B (8-bit)** | [`LiquidAI/d1-2B-MLX-8bit`](https://huggingface.co/LiquidAI/d1-2B-MLX-8bit) | 8-bit | about 2.2 GB | about 3.3 GB |
  | **Liquid d1-2B (4-bit)** | [`LiquidAI/d1-2B-MLX-4bit`](https://huggingface.co/LiquidAI/d1-2B-MLX-4bit) | 4-bit | about 1.4 GB | about 2.2 GB |

- Both run at the same speed and are released from memory when idle. The 8-bit build is the more accurate; the 4-bit build is for Macs with less memory. On 83 test images and 7 questions the two gave the same answer 566 times out of 581, and every difference was an image the 8-bit build was itself unsure about. One of the two is enough. Settings chooses which one careful steps use, and each keeps its own answers.

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

The decision model runs on Swift code in `macos/Sources/CurioKit/Engine/Decision`, written from [mlx-vlm](https://github.com/Blaizzy/mlx-vlm)'s implementation. To check it against that reference, download Liquid d1-2B (8-bit) in the app's Settings, then (for the 4-bit build: `D1_REPO=LiquidAI/d1-2B-MLX-4bit bash scripts/d1-reference.sh d1-2b-4bit`):

```bash
bash scripts/d1-reference.sh     # writes the reference's tokens, tensors and answers
bash scripts/check.sh            # the tests compare the Swift model with them
```

## License

MIT. MobileCLIP-S4's weights are published by Apple under its own [research licence](https://huggingface.co/apple/MobileCLIP-S4); Curio downloads it from a public copy, so read that licence before using or redistributing it.

Liquid d1-2B is published by Liquid AI under the [LFM Open License v1.0](https://huggingface.co/LiquidAI/d1-2B/blob/main/LICENSE), which does not license commercial use by an organisation with annual revenue of $10 million or more. Curio downloads it from Liquid AI and keeps the licence file with it. The code that runs it is adapted from mlx-vlm (Apache-2.0) and from the reference code shipped with the model.
