# Third party notices

AF Flow bundles or depends on the work below. Each entry names the licence its
author released it under. Nothing here is a claim by AF Flow over that work.

## Upstream project

| Project | Licence |
|---|---|
| [Ghost Pepper](https://github.com/matthartman/ghost-pepper) | MIT, declared in its README. See the note at the bottom of [LICENSE](LICENSE). |

## Swift packages

| Package | Licence |
|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT |
| [LLM.swift](https://github.com/obra/LLM.swift) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache 2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache 2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache 2.0 |
| [swift-syntax](https://github.com/apple/swift-syntax) | Apache 2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |

Apache 2.0 requires that its notice and attribution travel with the work. This
file is where they travel.

## Bundled assets

| Asset | Source | Licence |
|---|---|---|
| `Inter-variable.ttf` | [Inter](https://rsms.me/inter/) | SIL Open Font License 1.1 |
| `Fraunces-opsz9-wght500.ttf` | [Fraunces](https://fonts.google.com/specimen/Fraunces) | SIL Open Font License 1.1 |
| `cytoscape.min.js` | [Cytoscape.js](https://js.cytoscape.org/) | MIT |

## Models

AF Flow ships no model weights. On first use it downloads them from Hugging
Face and verifies them against a known hash. The weights stay under the terms
their publishers set, which are not restated here, because AF Flow neither
redistributes them nor bundles them:

- Speech recognition: OpenAI Whisper, converted for Core ML by the WhisperKit
  project, plus optional Parakeet models via FluidAudio.
- Text cleanup: a small local Qwen model.

Check the licence of a model on its Hugging Face page before using AF Flow for
anything commercial. That is a decision the person running the app makes, not
one this repository makes for them.
