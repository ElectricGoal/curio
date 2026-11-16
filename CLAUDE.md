# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Curio: a native macOS app (Apple Silicon, macOS 14+) that browses image folders and searches them by meaning with CLIP-style models running in-process on the GPU via Core ML. Swift only at runtime; Python is used solely by the one-time model conversion.

## Commands

Always go through `scripts/` (or `source scripts/env.sh` first): `env.sh` pins caches, `TMPDIR`, Hugging Face downloads etc. inside the checkout, and the build scripts set module-cache overrides.

```bash
bash scripts/convert-models.sh [alias]   # once: PyTorch -> Core ML into models/coreml/ (needs uv; ~2.4 GB download). Aliases: mobileclip-s4, clip-vit-b32
bash scripts/launch.sh                   # build dist/Curio.app (checkout-linked dev build) and open it
bash scripts/check.sh                    # swift test + release build + codesign verify + app --self-test
bash scripts/check.sh --e2e              # also the real end-to-end test against the default model

source scripts/env.sh
swift test --package-path macos                                   # all tests
swift test --package-path macos --filter IndexStoreTests          # one test class
swift test --package-path macos --filter IndexStoreTests/testName # one test
CURIO_E2E=1 [CURIO_E2E_MODEL=clip-vit-b32] [CURIO_SNAPSHOT_DIR=…] swift test --package-path macos --filter EndToEndTests

bash scripts/build-dmg.sh && bash scripts/check-dmg.sh            # self-contained release image (BUNDLE_MODELS, MODELS_URL, CODESIGN_IDENTITY, NOTARY_PROFILE)
```

There is no linter configured. With only the Command Line Tools (no Xcode), the macOS 27 SDK cannot build SwiftUI (missing `SwiftUIMacros` plugin) and XCTest is unavailable: build with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; tests need Xcode. Model-accuracy tests (`ModelFixtures`) skip themselves until models are converted; `EndToEndTests` skip unless `CURIO_E2E=1`. Release: pushing a `v*` tag runs `.github/workflows/release.yml`; version comes from `macos/VERSION` or `APP_VERSION`.

## Architecture

- **`macos/Sources/CurioKit`** — UI-free core, tested by `CurioKitTests`. `Engine/` is the search engine:
  - `SearchEngine` protocol is everything the app asks of its backend; `NativeEngine` (an actor, split across `+Indexing`/`+Search`) is the only implementation. Tests in `CurioTests` swap in a stand-in engine through `Studio(dataRoot:preferencesURL:engine:)`.
  - `EmbeddingModel` protocol isolates inference; `CoreMLEmbeddingModel` uses `.cpuAndGPU` deliberately (Neural Engine was measurably less faithful to PyTorch rankings — don't switch it). Model stays loaded between searches, released after 10 idle minutes.
  - `IndexStore`/`SQLiteDatabase`: one `index.sqlite` per photo folder in `<folder>/.curio/`. Vector and metadata share a row so interrupted runs stay consistent; rebuilds are written beside the old index and swapped in whole; undecodable files are recorded and not retried.
  - `ImagePreprocessor` (ImageIO: EXIF rotation, sRGB, alpha on white), `CLIPTokenizer`, `VectorMath`/`DuplicateFinder` (exact search with Accelerate, no ANN).
  - `ModelLibrary`/`ModelManifest`: models are folders produced by `scripts/convert_models.py` (`image.mlpackage`, `text.mlpackage`, `bpe_merges.txt`, `model.json`, `fixtures.json` = PyTorch reference outputs the Swift tests compare against, `files.json` = SHA-256 listing for downloads).
  - `SearchEngine.scores(folder:prompts:)` scores every indexed image against a list of prompts in one matrix multiply. `Curation.swift` turns that into tags, Clean Up (junk) groups and smart-album members (softmax over built-in `Labels`; albums are user text compared against each image's best built-in label). `Filter.swift` holds the Filter page's logic: `FilterRun` applies keep/remove `FilterStep`s in order, matching an image when it fits the step's prompt better than the neutral `FilterRun.baseline` ("a photo") by the strictness's lead; `FileExport` copies or moves results without overwriting. The same file as tags has `SearchRefinement` (image search steered by "+words, -words"). The duplicate finder uses a good-vs-bad-shot prompt direction to pick the best shot in groups of similar (non-resave) photos.
  - `ProgressEstimator` + `EngineProgress`: progress carries `fraction` (whole-task position across phases), `eta`, and `ceiling` (how far the bar may advance before the next report). Timings persist in `.runtime/timings.json`.
  - `Installation` decides where data lives: a **checkout** build (env `CURIO_PROJECT_ROOT`, or the project root baked into Info.plist by `scripts/info-plist.sh --project-root`) keeps models/caches in the repo; an **installed** build uses `~/Library/Application Support/Curio`.
- **`macos/Sources/Curio`** — SwiftUI app. `Studio` is the single `ObservableObject` app state, extended by `Studio+Engine` (runs engine work as the one visible `Activity` via `perform`, with cancel) and `Studio+Search`. `Studio+Curation` labels the folder quietly in the background after each index status check (`refreshCurationIfStale`) and serves tags, albums (saved in `Preferences.albums`) and the Clean Up page. `SelfTest` backs `Curio --self-test`, used by `check.sh` and `build-dmg.sh`.
- **Design system**: colours only in `CurioKit/Palette.swift` (contrast is unit-tested in `PaletteTests`); spacing/type/control styles in `Curio/Theme.swift`. Style is Minimalism/Swiss: monochrome, one accent, square corners, hairlines not shadows; viewer always dark; hover feedback off under Reduce Motion.

## Constraints

- Generated/large dirs are not source: `models/`, `.cache/`, `.runtime/`, `dist/`, `macos/.build`.
- Models are not bundled in releases. The app downloads them from the public Hugging Face repo `ElectricGoal/curio-models` (`AppEnvironment.defaultModelsURL`; override with `CURIO_MODELS_URL` or `MODELS_URL` at build time). On first launch with no model installed, `ModelSetupView` asks which to download (MobileCLIP-S4 preselected; it is under Apple's research licence, not MIT). After re-converting a model, upload `models/coreml/<alias>` there (minus `fixtures.json`), including its `files.json`, which the app verifies against.
- The user-facing name is Curio (bundle, data folder, `.curio` index dir, `CURIO_*` env vars, Info.plist `Curio*` keys); Swift modules are `Curio` (app) and `CurioKit` (core). Keep user-facing text saying "Curio".
