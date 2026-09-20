#!/usr/bin/env python3
"""Persistent, local Laya recommendation worker. stdout is a JSON-lines protocol."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
import unicodedata
from pathlib import Path

MAX_LINE_BYTES = 1024 * 1024
MAX_ENTRIES = 20
MAX_TEXT_CHARS = 32_768
KINDS = {"text", "url", "email", "code", "command", "phone", "file", "image", "color"}
KIND_NAMES = {
    "text": "文本", "url": "链接", "email": "邮箱", "code": "代码",
    "command": "命令", "phone": "电话", "path": "文件路径", "image": "图片", "color": "颜色",
}
TYPE_QUESTION = {
    "kind": {
        "type": "choice",
        "instructions": (
            "What type of clipboard content is needed in the currently focused input "
            "field, according to the task and application context?"
        ),
        "criteria": {
            "email": "an email address",
            "url": "a web URL or API endpoint",
            "code": "source code or SQL",
            "command": "a terminal shell command",
            "text": "plain text prose or a message",
            "phone": "a phone number",
            "path": "a local filesystem path",
            "color": "a hexadecimal or RGB color value",
        },
    }
}
STOP_WORDS = {
    "the", "a", "an", "of", "to", "and", "or", "is", "for", "in", "on", "at", "it",
    "i", "me", "my", "we", "you", "your", "this", "that", "with", "from", "need", "only",
    "current", "app", "field", "task", "please", "paste", "set", "environment", "string",
    "value", "list", "can", "could", "would", "should", "into", "want", "have", "has", "be",
    "as", "are", "was", "how", "do", "does", "then", "using",
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


def tokens(text):
    normalized = unicodedata.normalize("NFKC", text).lower()
    result = set()
    for token in re.findall(r"[a-z0-9_]+", normalized):
        if len(token) > 5 and token.endswith(("ches", "shes", "sses", "xes")):
            token = token[:-2]
        elif len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
            token = token[:-1]
        if len(token) > 1 and token not in STOP_WORDS:
            result.add(token)
    for word in re.findall(r"[\u3400-\u9fff]+", normalized):
        result.update(word[index:index + 2] for index in range(len(word) - 1))
    return result


def content_kind(entry):
    kind = entry["kind"]
    if kind != "text":
        return "path" if kind == "file" else kind
    text = entry["text"].strip()
    if re.fullmatch(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", text):
        return "email"
    if re.match(r"https?://\S+$", text, re.IGNORECASE):
        return "url"
    if re.match(r"(?:git|npm|pnpm|yarn|python3?|curl|ls|cd|brew|swift|xcrun)\s", text):
        return "command"
    if re.fullmatch(r"#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?(?:[0-9a-fA-F]{2})?", text):
        return "color"
    return "text"


def explicit_kind(context):
    field = context["fieldLabel"] + " " + context["fieldRole"]
    task = context["selectedText"] + " " + context["surroundingText"]
    patterns = [
        ("email", r"收件人|邮箱|邮件地址|\b(?:e-?mail|recipient|to address)\b"),
        ("url", r"网址|链接|\b(?:url|uri|website|web address|apiurl)\b"),
        ("phone", r"手机号|电话号码|\b(?:phone|telephone|mobile number)\b"),
        ("path", r"文件路径|目录路径|\b(?:file path|folder path|directory path)\b"),
        ("color", r"颜色值|色值|\b(?:hex color|hex colour|color value|rgb)\b"),
        ("command", r"终端命令|命令行|\b(?:shell prompt|shell command|terminal command)\b"),
        ("image", r"图片|图像|\b(?:image|picture|photo)\b"),
    ]
    for kind, pattern in patterns:
        if re.search(pattern, field, re.IGNORECASE):
            return kind
    # Require an explicit content request in prose; an app name is only a soft hint.
    task_patterns = {
        "email": r"邮箱|邮件地址|\be-?mail address\b",
        "url": r"网址|链接|\b(?:url|uri|apiurl)\b",
        "phone": r"手机号|电话号码|\b(?:phone number|telephone number)\b",
        "path": r"文件路径|目录路径|\b(?:file path|folder path)\b",
        "color": r"颜色值|色值|\b(?:hex color|hex colour|color value)\b",
        "command": r"终端命令|\b(?:shell command|terminal command)\b",
    }
    for kind, pattern in task_patterns.items():
        if re.search(pattern, task, re.IGNORECASE):
            return kind
    return None


def rank_entries(context, entries, probabilities):
    intent = explicit_kind(context)
    task = context["selectedText"] + " " + context["surroundingText"]
    context_tokens = tokens(task + " " + context["fieldLabel"])
    target_numbers = set(re.findall(r"(?<![A-Za-z])\d{2,}(?![A-Za-z])", task))
    ranked = []
    for index, entry in enumerate(entries):
        kind = content_kind(entry)
        overlap = context_tokens & tokens(entry["text"])
        lexical = min(6.0, sum(
            2.0 if token.isdigit() or re.search(r"[\u3400-\u9fff]", token) else 1.0
            for token in overlap
        ))
        numbers = set(re.findall(r"(?<![A-Za-z])\d{2,}(?![A-Za-z])", entry["text"]))
        precise_number = bool(target_numbers & numbers)
        kind_probability = probabilities.get(kind, 0.0)
        matches_field = intent is not None and kind == intent
        score = 2.0 * kind_probability + lexical + (3.0 if precise_number else 0.0)
        if intent:
            score += 3.0 if matches_field else -1.5
        score += 0.12 * (len(entries) - index) / max(1, len(entries))
        if matches_field and (lexical or precise_number):
            reason = "匹配当前输入位置与语境"
        elif precise_number:
            reason = "包含当前语境中的编号"
        elif lexical:
            reason = "与当前输入语境相关"
        elif matches_field:
            reason = "符合当前输入位置需要的" + KIND_NAMES[kind]
        elif kind_probability >= 0.4:
            reason = "Laya 判断当前适合粘贴" + KIND_NAMES[kind]
        else:
            reason = "最近复制的内容"
        ranked.append({"id": entry["id"], "score": round(score, 6), "reason": reason})
    return sorted(ranked, key=lambda item: -item["score"])


class RecommendationEngine:
    def __init__(self, backend, model_path, diagnostics):
        self.backend = backend
        self.model_path = Path(model_path).expanduser().resolve()
        self.diagnostics = diagnostics
        self.agent = None
        self.load_error = None
        self.cached_context = None
        self.cached_probabilities = None
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
                        or shape.get("max_length", 0) < 512 or shape.get("max_options", 0) < 8):
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

    def bounded_context(self, context):
        # Identity metadata is excluded by the protocol, not merely hidden in a prompt.
        state = {
            "focused_field": self.clipped_tokens(context["fieldLabel"], 80),
            "input_role": self.clipped_tokens(context["fieldRole"], 24),
            "application_category": context["applicationCategory"],
            "input_surface": context["inputSurface"],
            "selected_text": self.clipped_tokens(context["selectedText"], 144),
            "surrounding_text": self.clipped_tokens(context["surroundingText"], 384, tail=True),
        }
        empty, _ = self.agent.prepare("", TYPE_QUESTION)
        available = self.agent.cfg["max_len"] - len(empty[0]["ids"])
        encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        # Re-budget individual values instead of cutting a JSON string in the middle.
        # Retain the cursor end when reducing nearby text, including on 512-token models.
        for key in ("surrounding_text", "selected_text", "focused_field", "input_role", "input_surface", "application_category"):
            excess = len(self.agent.tok(encoded)["input_ids"]) - available
            if excess <= 0:
                break
            length = len(self.agent.tok(state[key])["input_ids"])
            state[key] = self.clipped_tokens(state[key], max(0, length - excess - 8),
                                              tail=key == "surrounding_text")
            encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        return encoded

    def infer_types(self, context):
        self.load()
        state = self.bounded_context(context)
        fingerprint = hashlib.sha256(state.encode("utf-8")).digest()
        if fingerprint == self.cached_context:
            return self.cached_probabilities
        self.inference_count += 1
        result = self.agent.predict(state, TYPE_QUESTION)
        probabilities = result["answers"]["kind"]["probabilities"]
        if not isinstance(probabilities, dict) or any(
            key not in probabilities or not isinstance(probabilities[key], (int, float))
            or not math.isfinite(probabilities[key]) or not 0 <= probabilities[key] <= 1
            for key in TYPE_QUESTION["kind"]["criteria"]
        ):
            raise ValueError("Invalid model probabilities")
        self.cached_context = fingerprint
        self.cached_probabilities = dict(probabilities)
        return self.cached_probabilities

    def respond(self, request_id, context, entries):
        started = time.perf_counter()
        self.inference_count = 0
        result = {
            "id": request_id, "recommendedID": None, "rankings": [], "mode": "fallback",
            "backend": self.backend, "elapsedMS": 0.0, "message": None,
            "decision": "empty_history", "shortlistedIDs": [entry["id"] for entry in entries],
            "inferenceCount": 0, "appliedFacets": [],
        }
        if context["isSecure"]:
            self.cached_context = self.cached_probabilities = None
            result["rankings"] = [
                {"id": entry["id"], "score": 0.0, "reason": "按复制时间排列"}
                for entry in entries
            ]
            result["message"] = "安全输入框已暂停语境推荐。"
            result["decision"] = "secure_field"
        elif entries and not any(context[key].strip() for key in ("fieldLabel", "selectedText", "surroundingText")):
            result["decision"] = "insufficient_context"
            result["message"] = "当前语境不足 · 按复制时间排列"
        elif entries:
            probabilities = {}
            try:
                probabilities = self.infer_types(context)
                result["mode"] = "laya"
            except Exception as error:  # noqa: BLE001 - runtime failures must preserve usable history.
                result["message"] = self.load_error or "本次 Laya 推理未完成，已使用本地匹配。"
                if not self.load_error:
                    self.diagnostics.write("PasteWhat: inference failed (" + type(error).__name__ + ").\n")
                    self.diagnostics.flush()
            result["rankings"] = rank_entries(context, entries, probabilities)
            result["recommendedID"] = result["rankings"][0]["id"]
            result["decision"] = "recommended"
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
        engine = RecommendationEngine(args.backend, args.model, diagnostics)
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
