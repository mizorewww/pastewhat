# PasteWhat

A native AppKit menu bar clipboard companion for macOS. PasteWhat uses Laya and the active app's context to recommend what to paste from the latest 20 clipboard entries.

Development is beginning with documentation and an investigation of the sibling `laya-mlx` and `laya-coreml` projects.

## Development principles

- Design before implementation; no test-driven development.
- Consult current documentation before choosing platform and inference APIs.
- Keep changes in focused, atomic Git commits.
- Remove temporary scaffold tests once the implementation is stable.
- Keep clipboard contents, local model files, and user-specific configuration out of Git.
