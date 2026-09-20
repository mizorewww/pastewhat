#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: scripts/setup-engine.sh [--backend mlx|coreml] [--model /existing/model]
                               [--use-sibling] [--support-dir /directory]

Install a pinned Laya runtime and the general multilingual model, then write
~/Library/Application Support/PasteWhat/engine.json. MLX is the default.
Requires uv (https://docs.astral.sh/uv/getting-started/installation/).

--model          Use an existing local model instead of downloading weights.
--use-sibling    Reuse ../laya-mlx or ../laya-coreml without modifying that repo.
--support-dir    Use another application-support directory (for development).
HELP
}

backend="mlx"
model_path=""
use_sibling=0
support_dir="$HOME/Library/Application Support/PasteWhat"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --backend|--model|--support-dir)
            if [ "$#" -lt 2 ] || [[ "$2" == --* ]]; then
                echo "Missing value for $1" >&2
                exit 2
            fi
            case "$1" in
                --backend) backend="$2" ;;
                --model) model_path="$2" ;;
                --support-dir) support_dir="$2" ;;
            esac
            shift 2 ;;
        --use-sibling) use_sibling=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [ "$backend" != "mlx" ] && [ "$backend" != "coreml" ]; then
    echo "Backend must be mlx or coreml." >&2
    exit 2
fi
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "PasteWhat requires an Apple silicon Mac." >&2
    exit 1
fi

umask 077
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$support_dir"
chmod 700 "$support_dir"
if [ "$use_sibling" -eq 1 ]; then
    sibling_dir="$(dirname -- "$project_dir")/laya-$backend"
    engine_python="$sibling_dir/.venv/bin/python"
    if [ ! -x "$engine_python" ]; then
        echo "The sibling Python environment is missing. Run without --use-sibling to install one." >&2
        exit 1
    fi
    if [ -z "$model_path" ]; then
        model_path="$sibling_dir/models/hub/laya-multilingual-$backend"
    fi
else
    if ! command -v uv >/dev/null 2>&1; then
        echo "Install uv first: https://docs.astral.sh/uv/getting-started/installation/" >&2
        exit 1
    fi
    runtime_dir="$support_dir/runtime"
    if [ ! -x "$runtime_dir/bin/python" ]; then
        uv venv --python 3.12 "$runtime_dir"
    fi
    engine_python="$runtime_dir/bin/python"
    uv pip install --python "$engine_python" "laya-$backend==0.1.0"
fi

"$engine_python" - "$backend" "$support_dir" "$model_path" <<'PY'
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import tempfile

backend, support, supplied_model = sys.argv[1:]
support = Path(support).expanduser().resolve()
package = "laya-" + backend
if importlib.metadata.version(package) != "0.1.0":
    raise SystemExit("Expected " + package + "==0.1.0 in the selected Python environment.")
model = Path(supplied_model).expanduser().resolve() if supplied_model else (
    support / "Models" / ("laya-multilingual-" + backend)
)
if not supplied_model:
    from huggingface_hub import snapshot_download
    print("Downloading the general multilingual model for " + backend + "…", flush=True)
    patterns = ["rl_agent_config.json", "encoder/config.json", "tokenizer/*", "LICENSE*", "NOTICE*"]
    patterns += ["model.safetensors", "mlx_config.json"] if backend == "mlx" else [
        "coreml_config.json", "model.mlpackage/**"
    ]
    snapshot_download("aac6fef/laya-multilingual-" + backend, local_dir=str(model), allow_patterns=patterns)
required = ["rl_agent_config.json", "encoder/config.json", "tokenizer/tokenizer.json",
            "tokenizer/tokenizer_config.json"]
required.append("model.safetensors" if backend == "mlx" else "coreml_config.json")
if not model.is_dir() or any(not (model / name).is_file() for name in required):
    raise SystemExit("The local model is incomplete; engine.json was not changed.")
agent_config = json.loads((model / "rl_agent_config.json").read_text())
if agent_config.get("max_len", 0) < 512:
    raise SystemExit("Use a general model with at least 512 tokens of context.")
if backend == "coreml":
    manifest = json.loads((model / "coreml_config.json").read_text())
    shape = manifest.get("shape", {})
    if (manifest.get("format") != "laya-coreml" or not (model / "model.mlpackage").is_dir()
            or shape.get("max_length", 0) < 512 or shape.get("max_options", 0) < 8):
        raise SystemExit("Use the general multilingual Core ML model, not a short-context ANE export.")
    if shape.get("flexible") and not shape.get("lengths"):
        raise SystemExit("Core ML CPU + GPU requires the validated enumerated-shape model.")
configuration = {"backend": backend, "pythonPath": sys.executable, "modelPath": str(model)}
temporary_name = None
try:
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=support,
                                     prefix=".engine-", delete=False) as temporary:
        temporary_name = temporary.name
        os.fchmod(temporary.fileno(), 0o600)
        json.dump(configuration, temporary, ensure_ascii=False, indent=2)
        temporary.write("\n")
        temporary.flush()
        os.fsync(temporary.fileno())
    os.replace(temporary_name, support / "engine.json")
finally:
    if temporary_name and os.path.exists(temporary_name):
        os.unlink(temporary_name)
print("Laya " + backend + " is configured. Restart PasteWhat to use it.")
print("Configuration: " + str(support / "engine.json"))
PY
