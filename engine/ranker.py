"""App protocol adapter for the calibrated PasteWhat-Ranker MLX artifact."""

from __future__ import annotations

import hashlib
import json
import time
from collections import OrderedDict
from pathlib import Path


class RankerEngine:
    def __init__(self, model_path, diagnostics):
        self.model_path = Path(model_path).expanduser().resolve()
        self.diagnostics = diagnostics
        self.scorer = None
        self.calibrator = None
        self.policy = None
        self.cache = OrderedDict()

    def load(self):
        if self.scorer is not None:
            return
        required = ("model.safetensors", "config.json", "preprocess.json", "calibrator.json", "tokenizer/tokenizer.json")
        if any(not (self.model_path / name).is_file() for name in required):
            raise ValueError("Incomplete calibrated ranker artifact")
        from pastewhat_ranker.calibration import apply_calibration, load_calibrator
        from pastewhat_ranker.worker import RankerScorer
        calibrator = load_calibrator(self.model_path / "calibrator.json",
                                     weights_path=self.model_path / "model.safetensors",
                                     preprocess_path=self.model_path / "preprocess.json", require_accepted=True)
        scorer = RankerScorer(self.model_path, backend="mlx")
        self.calibrator, self.scorer, self.policy = calibrator, scorer, apply_calibration

    def respond(self, request_id, context, entries):
        started = time.perf_counter()
        result = {"id": request_id, "recommendedID": None, "rankings": [], "mode": "ranker",
                  "backend": "ranker", "elapsedMS": 0, "message": None, "decision": "empty_history",
                  "shortlistedIDs": [], "inferenceCount": 0, "appliedFacets": [],
                  "modelVersion": "PasteWhat-Ranker-v1"}
        if context["isSecure"]:
            self.cache.clear()
            result.update(decision="secure_field", message="安全输入框已暂停语境推荐。")
        elif entries:
            # This model was trained on complete groups. The encoder and abstain
            # head must see all candidates; the UI also retains the full history.
            result["shortlistedIDs"] = [entry["id"] for entry in entries]
            episode = {"id": request_id, "context": context, "entries": entries}
            fingerprint = hashlib.sha256(json.dumps({"context": context, "entries": entries},
                                                     ensure_ascii=False, sort_keys=True).encode()).digest()
            try:
                self.load()
                if fingerprint in self.cache:
                    raw = {**self.cache[fingerprint], "id": request_id}
                    self.cache.move_to_end(fingerprint)
                else:
                    result["inferenceCount"] = 1
                    raw = self.scorer.score(episode)
                    self.cache[fingerprint] = raw
                    while len(self.cache) > 16:
                        self.cache.popitem(last=False)
                decision = self.policy(episode, raw, self.calibrator)
                if decision.get("error") or decision["decision"] == "inference_failure":
                    raise ValueError("Invalid score or calibration result")
                result["rankings"] = sorted(
                    [{"id": item["id"], "score": item["score"],
                      "reason": "专用本地模型结合完整候选排序，并通过推荐阈值。"}
                     for item in decision["candidateScores"]], key=lambda item: -item["score"])
                result["recommendedID"] = decision["recommendedID"]
                result["decision"] = "recommended" if decision["recommendedID"] is not None else "model_abstained"
                result["appliedFacets"] = ["candidate_rank", "group_abstain", "calibration"]
                result["message"] = ("PasteWhat Ranker · MLX · 已在本机推荐" if decision["recommendedID"]
                                     else "专用模型未找到明确推荐 · 按复制时间排列")
            except Exception as error:
                result.update(decision="model_unavailable",
                              message="专用模型未就绪或校准校验失败 · 请在设置中选择完整发布模型")
                self.diagnostics.write("PasteWhat: ranker unavailable (" + type(error).__name__ + ").\n")
                self.diagnostics.flush()
        result["elapsedMS"] = round((time.perf_counter() - started) * 1000, 3)
        return result
