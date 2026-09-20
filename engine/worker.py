#!/usr/bin/env python3
"""Persistent, local Laya recommendation worker. stdout is a JSON-lines protocol."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import time
from pathlib import Path
from collections import OrderedDict

# This worker lives inside a signed app bundle. Set this before importing sibling
# modules; doing it only in main() writes __pycache__ into the sealed resources.
sys.dont_write_bytecode = True
from ranking import extract_features, make_intent, preselect, useful_facets, score_candidates, decide, public_rankings

MAX_LINE_BYTES = 1024 * 1024
MAX_ENTRIES = 20
MAX_TEXT_CHARS = 32_768
KINDS = {"text", "url", "email", "code", "command", "phone", "file", "image", "color"}
QUESTIONS = {
    "kind": {
        "type": "choice",
        "instructions": "Which content is needed at the focused input? Follow the task and field, not the application category. Choose unknown if not specified.",
        "criteria": {"email": "email address", "url": "web link or API URL", "code": "source code or SQL",
                     "command": "shell command", "text": "prose or message", "phone": "phone number",
                     "path": "file or filesystem path", "color": "color value", "image": "image or screenshot",
                     "unknown": "not specified or insufficient context"},
    },
    "environment": {
        "type": "choice",
        "instructions": "Which deployment environment does the current task need? Respect negations. Choose unknown if no environment is requested.",
        "criteria": {"local": "local development", "testing": "testing or sandbox", "staging": "staging or pre-production",
                     "production": "live production", "unknown": "not specified"},
    },
    "purpose": {
        "type": "choice",
        "instructions": "What is the requested link used for in the current task? Choose unknown if the purpose is not specified.",
        "criteria": {"api": "API endpoint or webhook", "documentation": "documentation or reference guide",
                     "issue": "issue or bug tracking", "repository": "source repository", "unknown": "not specified"},
    },
}
CONTEXT_LIMITS = {
    "applicationCategory": 64, "inputSurface": 64,
    "fieldRole": 256, "fieldLabel": 2_048,
    "selectedText": 8_192, "surroundingText": 16_384,
}
CATEGORIES = {"browser", "development", "terminal", "mail", "messaging", "writing",
              "spreadsheet", "creative", "file_management", "unknown"}
SURFACES = {"unknown", "text", "recipient", "address_bar", "search", "code_editor",
            "shell_prompt", "chat_composer", "document", "cell", "color", "file_path", "phone"}


class InvalidRequest(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidRequest("请求包含重复字段。")
        result[key] = value
    return result


def reject_constant(_):
    raise InvalidRequest("请求包含无效数字。")


def valid_id(value):
    return (
        isinstance(value, str) and 0 < len(value) <= 128
        and all(ord(character) >= 32 and not 0xD800 <= ord(character) <= 0xDFFF for character in value)
    )


def bounded_string(value, limit):
    if not isinstance(value, str) or len(value) > MAX_TEXT_CHARS:
        raise InvalidRequest("请求中的文字格式或长度无效。")
    if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
        raise InvalidRequest("请求中的文字编码无效。")
    return value[:limit]


def validate_request(raw):
    if not isinstance(raw, dict) or not valid_id(raw.get("id")):
        raise InvalidRequest("请求标识无效。")
    context = raw.get("context")
    entries = raw.get("entries")
    if not isinstance(context, dict) or not isinstance(entries, list):
        raise InvalidRequest("请求需要语境和剪贴板列表。")
    if len(entries) > MAX_ENTRIES:
        raise InvalidRequest("每次推荐最多接受 20 条剪贴板记录。")
    if set(context) - (set(CONTEXT_LIMITS) | {"hasAccessibility", "isSecure"}):
        raise InvalidRequest("推理语境只能包含应用类别与输入区域信息。")
    clean_context = {}
    for key, limit in CONTEXT_LIMITS.items():
        value = context.get(key, "unknown" if key in ("applicationCategory", "inputSurface") else "")
        clean_context[key] = bounded_string(value, limit)
        if key == "surroundingText":
            clean_context[key] = value[-limit:]
    for key in ("hasAccessibility", "isSecure"):
        value = context.get(key, False)
        if not isinstance(value, bool):
            raise InvalidRequest("语境状态格式无效。")
        clean_context[key] = value
    if clean_context["applicationCategory"] not in CATEGORIES or clean_context["inputSurface"] not in SURFACES:
        raise InvalidRequest("应用类别或输入区域类型无效。")
    clean_entries, seen = [], set()
    for entry in entries:
        if not isinstance(entry, dict) or not valid_id(entry.get("id")):
            raise InvalidRequest("剪贴板记录标识无效。")
        if entry["id"] in seen:
            raise InvalidRequest("剪贴板记录标识重复。")
        seen.add(entry["id"])
        if entry.get("kind") not in KINDS:
            raise InvalidRequest("剪贴板内容类型无效。")
        if set(entry) - {"id", "text", "kind", "capabilities", "sourceCategory"}:
            raise InvalidRequest("候选记录不能包含应用身份信息。")
        capabilities = entry.get("capabilities", [])
        if (not isinstance(capabilities, list) or not 1 <= len(capabilities) <= 4
                or any(not isinstance(item, str) or item not in {"text", "image", "file", "richText"} for item in capabilities)
                or len(set(capabilities)) != len(capabilities)):
            raise InvalidRequest("剪贴板表示类型无效。")
        source_category = entry.get("sourceCategory", "unknown")
        if not isinstance(source_category, str) or source_category not in CATEGORIES:
            raise InvalidRequest("来源类别无效。")
        clean_entries.append({
            "id": entry["id"],
            "text": bounded_string(entry.get("text"), 8_192),
            "kind": entry["kind"],
            "capabilities": capabilities,
            "sourceCategory": source_category,
        })
    return raw["id"], clean_context, clean_entries



class RecommendationEngine:
    def __init__(self, backend, model_path, diagnostics, *, no_model=False):
        self.backend = backend
        self.model_path = Path(model_path).expanduser().resolve()
        self.diagnostics = diagnostics
        self.agent = None
        self.load_error = None
        self.no_model = no_model
        self.cache = OrderedDict()
        self.inference_count = 0

    def load(self):
        if self.agent is not None:
            return
        if self.load_error:
            raise RuntimeError(self.load_error)
        try:
            required = ["rl_agent_config.json", "encoder/config.json", "tokenizer/tokenizer.json",
                        "tokenizer/tokenizer_config.json"]
            required.append("model.safetensors" if self.backend == "mlx" else "coreml_config.json")
            if not self.model_path.is_dir() or any(
                not (self.model_path / name).is_file() for name in required
            ):
                self.load_error = "本地 Laya 模型尚未准备好，已使用本地匹配。"
                raise FileNotFoundError()
            if self.backend == "mlx":
                from laya_mlx import load
                self.agent = load(self.model_path, dtype="float16", batch_size=1)
            else:
                manifest = json.loads((self.model_path / "coreml_config.json").read_text())
                shape = manifest.get("shape", {})
                if (manifest.get("format") != "laya-coreml"
                        or shape.get("max_length", 0) < 512 or shape.get("max_options", 0) < len(QUESTIONS["kind"]["criteria"])):
                    self.load_error = "请选择通用 Core ML 模型；短语境 ANE 模型不适用于此任务。"
                    raise ValueError()
                from laya_coreml import load
                self.agent = load(self.model_path, compute_units="cpu_gpu", local_files_only=True)
            if self.agent.cfg.get("max_len", 0) < 512:
                self.agent = None
                self.load_error = "模型语境容量不足，请选择通用 multilingual 模型。"
                raise ValueError()
        except Exception as error:
            self.agent = None
            self.load_error = self.load_error or "Laya 暂时不可用，已使用本地匹配。请检查引擎配置。"
            self.diagnostics.write("PasteWhat: backend load failed (" + type(error).__name__ + ").\n")
            self.diagnostics.flush()
            raise

    def clipped_tokens(self, value, limit, *, tail=False):
        if limit <= 0:
            return ""
        token_ids = self.agent.tok(value, add_special_tokens=False)["input_ids"]
        if len(token_ids) <= limit:
            return value
        selected = token_ids[-limit:] if tail else token_ids[:limit]
        return self.agent.tok.backend.decode(selected, skip_special_tokens=False)

    def bounded_context(self, context, question):
        state = {
            "application_category": context["applicationCategory"],
            "input_surface": context["inputSurface"],
            "focused_field": self.clipped_tokens(context["fieldLabel"], 80),
            "input_role": self.clipped_tokens(context["fieldRole"], 24),
            "selected_text": self.clipped_tokens(context["selectedText"], 144),
            "surrounding_text": self.clipped_tokens(context["surroundingText"], 384, tail=True),
        }
        empty, _ = self.agent.prepare("", question)
        available = self.agent.cfg["max_len"] - len(empty[0]["ids"]) - 8
        encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        for key in ("surrounding_text", "selected_text", "focused_field", "input_role", "input_surface", "application_category"):
            excess = len(self.agent.tok(encoded)["input_ids"]) - available
            if excess <= 0:
                break
            length = len(self.agent.tok(state[key])["input_ids"])
            state[key] = self.clipped_tokens(state[key], max(0, length - excess - 8), tail=key == "surrounding_text")
            encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        if len(self.agent.tok(encoded)["input_ids"]) > available:
            raise ValueError("Insufficient context budget")
        return encoded

    def infer(self, context, name):
        self.load()
        question = {name: QUESTIONS[name]}
        state = self.bounded_context(context, question)
        fingerprint = hashlib.sha256((name + state).encode("utf-8")).digest()
        if fingerprint in self.cache:
            self.cache.move_to_end(fingerprint)
            return self.cache[fingerprint]
        self.inference_count += 1
        result = self.agent.predict(state, question)
        probabilities = result["answers"][name]["probabilities"]
        if not isinstance(probabilities, dict) or any(
            key not in probabilities or type(probabilities[key]) not in (int, float)
            or not math.isfinite(probabilities[key]) or not 0 <= probabilities[key] <= 1
            for key in QUESTIONS[name]["criteria"]
        ):
            raise ValueError("Invalid model probabilities")
        self.cache[fingerprint] = dict(probabilities)
        while len(self.cache) > 24:
            self.cache.popitem(last=False)
        return self.cache[fingerprint]

    def respond(self, request_id, context, entries):
        started = time.perf_counter()
        self.inference_count = 0
        result = {
            "id": request_id, "recommendedID": None, "rankings": [], "mode": "fallback",
            "backend": self.backend, "elapsedMS": 0.0, "message": None,
            "decision": "empty_history", "shortlistedIDs": [], "inferenceCount": 0, "appliedFacets": [],
        }
        if context["isSecure"]:
            self.cache.clear()
            result.update(decision="secure_field", message="安全输入框已暂停语境推荐。")
        elif entries:
            features = extract_features(entries)
            intent = make_intent(context)
            shortlist = preselect(features, intent)
            result["shortlistedIDs"] = [feature.entry["id"] for feature in shortlist]
            signals = {}
            runtime_message = None
            if intent.has_context and shortlist and not self.no_model:
                try:
                    for name in ["kind", *useful_facets(shortlist, intent)]:
                        signals[name] = self.infer(context, name)
                        result["appliedFacets"].append(name)
                    result["mode"] = "laya"
                except Exception as error:
                    signals = {}
                    result["appliedFacets"] = []
                    runtime_message = self.load_error or "本次 Laya 推理未完成，已使用本地匹配。"
                    if not self.load_error:
                        self.diagnostics.write("PasteWhat: inference failed (" + type(error).__name__ + ").\n")
                        self.diagnostics.flush()
            ranked = score_candidates(shortlist, intent, signals)
            recommendation, decision, message = decide(ranked, intent, signals)
            result.update(recommendedID=recommendation, decision=decision,
                          rankings=public_rankings(ranked), message=message or runtime_message)
        result["elapsedMS"] = round((time.perf_counter() - started) * 1000, 3)
        result["inferenceCount"] = self.inference_count
        return result


def failure_response(backend, message, request_id=""):
    return {
        "id": request_id, "recommendedID": None, "rankings": [], "mode": "fallback",
        "backend": backend, "elapsedMS": 0.0, "message": message,
        "decision": "invalid_request", "shortlistedIDs": [], "inferenceCount": 0, "appliedFacets": [],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("mlx", "coreml"), default="mlx")
    parser.add_argument("--model", required=True, help="Existing local model directory")
    parser.add_argument("--no-model", action="store_true", help="Evaluate local retrieval without loading Laya")
    args = parser.parse_args()
    for name, value in {
        "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TRANSFORMERS_OFFLINE": "1",
        "DO_NOT_TRACK": "1", "TOKENIZERS_PARALLELISM": "false", "PYTHONDONTWRITEBYTECODE": "1",
    }.items():
        os.environ[name] = value
    sys.dont_write_bytecode = True
    # Native runtimes can print from C as well as Python. Preserve dedicated protocol
    # and diagnostic descriptors, and discard all third-party stdout/stderr output.
    with os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1) as protocol, \
         os.fdopen(os.dup(sys.stderr.fileno()), "w", encoding="utf-8", buffering=1) as diagnostics, \
         open(os.devnull, "w") as quiet:
        os.dup2(quiet.fileno(), sys.stdout.fileno())
        os.dup2(quiet.fileno(), sys.stderr.fileno())
        engine = RecommendationEngine(args.backend, args.model, diagnostics, no_model=args.no_model)
        while True:
            line = sys.stdin.buffer.readline(MAX_LINE_BYTES + 1)
            if not line:
                break
            request_id = ""
            if len(line) > MAX_LINE_BYTES:
                while line and not line.endswith(b"\n"):
                    line = sys.stdin.buffer.readline(MAX_LINE_BYTES + 1)
                result = failure_response(args.backend, "请求过大，请缩短语境与剪贴板摘要。")
            else:
                try:
                    raw = json.loads(line, object_pairs_hook=unique_object, parse_constant=reject_constant)
                    if isinstance(raw, dict) and valid_id(raw.get("id")):
                        request_id = raw["id"]
                    request_id, context, entries = validate_request(raw)
                    result = engine.respond(request_id, context, entries)
                except InvalidRequest as error:
                    result = failure_response(args.backend, str(error), request_id)
                except (ValueError, TypeError, UnicodeError, RecursionError):
                    result = failure_response(args.backend, "请求不是有效的剪贴板推荐 JSON。", request_id)
                except Exception as error:  # noqa: BLE001 - each request must receive a JSON response.
                    diagnostics.write("PasteWhat: request failed (" + type(error).__name__ + ").\n")
                    diagnostics.flush()
                    result = failure_response(args.backend, "本次推荐未完成，请重试。", request_id)
            try:
                protocol.write(json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
            except (BrokenPipeError, OSError):
                break


if __name__ == "__main__":
    main()
