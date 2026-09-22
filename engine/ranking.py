"""Bounded, local candidate retrieval and evidence-based recommendation decisions.

No model/runtime imports. Raw clipboard payloads and application identities never enter
this module. Scores are ordering evidence, not calibrated correctness probabilities.
"""

from __future__ import annotations

import math
import re
import unicodedata
from collections import Counter
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit

STOP_TERMS = """the a an of to and or is for in on at it i me my we you your this that with
from need current app field task please paste set environment string value list can
could would should into want have has be as are was how do does then using use here
there enter input insert copy copied clipboard content provide give send put get
needed correct appropriate suitable new actual following below above selected
http https www com org net example recipient address email url uri link phone number
color colour hex file folder path image picture photo code command text message
only just not no don't without instead than but any some all something nothing
now find choose select show an e mail for our their its type format option
"""
STOP = set(STOP_TERMS.split())

KIND_PATTERNS = {
    "email": r"\b(?:e-?mail(?: address)?|recipient)\b|邮箱|邮件地址|收件人",
    "url": r"\b(?:url|uri|link|website|web address|endpoint)\b|网址|链接|接口地址",
    "phone": r"\b(?:phone|telephone|mobile)(?: number)?\b|手机号|电话号码",
    "path": r"\b(?:file path|folder path|directory path)\b|文件路径|目录路径",
    "color": r"\b(?:hex colou?r|colou?r(?: value| code)?|rgb)\b|颜色值|色值",
    "command": r"\b(?:(?:shell|terminal) command|shell prompt|command line|command)\b|终端命令|命令行|命令",
    "code": r"\b(?:source code|code snippet|code|sql query)\b|代码|查询语句",
    "image": r"\b(?:image|picture|photo|screenshot)\b|图片|图像|截图",
    "file": r"\b(?:attachment|file upload|attach(?: a| the)? file)\b|附件|上传文件",
    "text": r"\b(?:plain text|prose|paragraph|sentence|explanation|reply|greeting)\b|说明文字|解释文字|段落|回复|问候",
}
ENV_PATTERNS = {
    "local": r"\b(?:localhost|127\.0\.0\.1|local|development|dev)\b|本地|开发环境",
    "testing": r"\b(?:test(?:ing)?|sandbox|qa)\b|测试|沙箱",
    "staging": r"\b(?:staging|stage|preprod|pre-production)\b|预发布|预生产",
    "production": r"\b(?:production|prod|live)\b|生产|线上|正式环境",
}
PURPOSE_PATTERNS = {
    "api": r"\b(?:api|endpoint|webhook|callback)\b|接口|回调",
    "documentation": r"\b(?:docs?|documentation|manual|reference|guide)\b|文档|手册|指南",
    "issue": r"\b(?:issues?|tickets?|bugs?)\b|工单|问题编号|缺陷",
    "repository": r"\b(?:repository|repo|source repository)\b|仓库|源码仓库",
}
SURFACE_KIND = {"recipient": "email", "address_bar": "url", "shell_prompt": "command",
                "code_editor": "code", "color": "color", "file_path": "path", "phone": "phone"}
NEGATION_TERMS = r"\b(?:not|no|without|except|excluding|avoid|rather than|instead of|don't|do not)\b|不要|不是|不含|排除|而非|别用"
NEGATION = re.compile(r"(?:" + NEGATION_TERMS + r")\s*", re.IGNORECASE)
EMAIL = re.compile(r"[\w.+-]+@[\w.-]+\.[a-z]{2,}", re.IGNORECASE)
URL = re.compile(r"https?://[^\s<>\"']+", re.IGNORECASE)


def normalized(text):
    return unicodedata.normalize("NFKC", text).casefold()


def terms(text):
    text = re.sub(r"([a-z])([A-Z])", r"\1 \2", text)
    text = normalized(text)
    result = set()
    # Flags and operators retain their identity, including one-character options.
    result.update("flag:" + flag for flag in re.findall(r"(?<![\w-])--?[a-z][\w-]*", text))
    result.update("op:" + op for op in re.findall(r"!=|==|<=|>=|&&|\|\|", text))
    for token in re.findall(r"[a-z0-9]+", text):
        if len(token) > 5 and token.endswith(("ches", "shes", "sses", "xes")):
            token = token[:-2]
        elif len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
            token = token[:-1]
        if len(token) > 1 and not token.isdigit() and token not in STOP:
            result.add(token)
            # A small, language-neutral-to-identifiers morphology channel: keep the exact
            # token as well, so normalization never erases command/identifier differences.
            for suffix in ("ation", "ing", "ed"):
                if len(token) > len(suffix) + 3 and token.endswith(suffix):
                    result.add("stem:" + token[:-len(suffix)])
                    break
    for word in re.findall(r"[\u3400-\u9fff]+", text):
        result.update(word[i:i + 2] for i in range(len(word) - 1))
    return result


def negative_at(text, start):
    prefix = re.split(r"[,.;!?，。；！？\n]|\b(?:but|instead|and then)\b|而是|但是", text[:start], flags=re.IGNORECASE)[-1]
    matches = list(NEGATION.finditer(prefix))
    return bool(matches and len(prefix) - matches[-1].end() <= 40)


def signed_labels(text, patterns):
    positive, negative = set(), set()
    for label, pattern in patterns.items():
        for match in re.finditer(pattern, text, re.IGNORECASE):
            (negative if negative_at(text, match.start()) else positive).add(label)
    # Conflicting mentions are ambiguous; never silently convert them into a hard constraint.
    return positive - negative, negative - positive


def positive_text(text):
    return re.sub(
        r"(?:" + NEGATION_TERMS + r")[^,.;!?，。；！？\n]*",
        " ", text, flags=re.IGNORECASE,
    )


def entities(text):
    text = normalized(text)
    result = set()
    for match in re.finditer(r"(?:\b(?:issue|ticket|bug)\s*#?\s*|(?:工单|问题|缺陷)\s*#?\s*|(?<!\w)#)(\d{1,9})\b", text):
        result.add(("issue", match[1]))
    for match in re.finditer(r"\b([a-z]{2,10}-\d{1,9})\b", text):
        result.add(("ticket", match[1]))
    for match in re.finditer(r"(?:\bport\s*[:=]?\s*|端口\s*)(\d{2,5})\b", text):
        result.add(("port", match[1]))
    for match in re.finditer(r"\b(?:version\s*|v)(\d+(?:\.\d+){0,3})\b|版本\s*(\d+(?:\.\d+){0,3})", text):
        result.add(("version", match[1] or match[2]))
    for match in re.finditer(r"(?:\b(?:pdf|png|jpg|jpeg|svg|csv|xlsx|docx|json|yaml|toml|zip)\b)", text):
        result.add(("format", "jpg" if match[0] == "jpeg" else match[0]))
    for match in URL.finditer(text):
        raw = match[0].rstrip(".,;，。；)")
        result.add(("url", raw.rstrip("/")))
        try:
            parsed = urlsplit(raw)
            for issue in re.finditer(r"/(?:issues?|tickets?|pull)/([0-9]+)(?:/|$)", parsed.path):
                result.add(("issue", issue[1]))
            if parsed.port:
                result.add(("port", str(parsed.port)))
        except ValueError:
            pass
    if "@" in text:
        result.update(("email", match[0]) for match in EMAIL.finditer(text))
    for match in re.finditer(r"[\"“「]([^\"”」\n]{2,160})[\"”」]", text):
        result.add(("literal", match[1]))
    for match in re.finditer(r"\b(?:starting|starts|beginning|begins) with\s+([^\n。]{2,100})", text):
        value = match[1].strip().strip('"“”').rstrip(". ")
        if value:
            result.add(("prefix", value))
    for match in re.finditer(r"以\s*[\"“]?([^\n。]{2,100}?)[\"”]?\s*开头", text):
        result.add(("prefix", match[1].strip()))
    return result


LANGUAGE_PATTERNS = {
    "swift": r"\bswift\b|\bfunc\s+\w+\s*\([^)]*\)\s*->|\b(?:struct|class)\s+\w+\s*:\s*(?:View|NSObject)",
    "python": r"\bpython\b|\bdef\s+\w+\s*\([^)]*\)\s*:|^\s*from\s+[\w.]+\s+import\b",
    "javascript": r"\bjavascript\b|\bfunction\s+\w+\s*\(|\b(?:const|let)\s+\w+\s*=\s*(?:async\s*)?\([^)]*\)\s*=>",
    "typescript": r"\btypescript\b|\binterface\s+\w+\s*\{|\btype\s+\w+\s*=",
    "sql": r"\bsql\b|\bselect\b[\s\S]*\bfrom\b|\binsert\s+into\b|\bcreate\s+table\b",
    "rust": r"\brust\b|\bfn\s+\w+\s*\(|\bimpl\s+\w+\s*\{",
    "go": r"\bgolang\b|\bgo code\b|\bpackage\s+main\b",
    "java": r"\bjava\b|\bpublic\s+(?:static\s+)?(?:class|void|int|String)\b",
}


def structural_entities(text, *, candidate=False):
    result = set()
    for language, pattern in LANGUAGE_PATTERNS.items():
        if re.search(pattern, text, re.IGNORECASE | re.MULTILINE):
            result.add(("code_language", language))
    # Syntax-aware equivalents, not a mapping from task examples to particular snippets.
    if candidate:
        if re.search(r"\border\s+by\b[^;\n]*\bdesc\b", text, re.IGNORECASE):
            result.add(("sort_direction", "descending"))
        if re.search(r"\border\s+by\b[^;\n]*\basc\b", text, re.IGNORECASE):
            result.add(("sort_direction", "ascending"))
        if re.match(r"\s*(?://|/\*|# |-- )", text):
            result.add(("code_form", "comment"))
    else:
        if re.search(r"\bdescending\b|降序|从大到小", text, re.IGNORECASE):
            result.add(("sort_direction", "descending"))
        if re.search(r"\bascending\b|升序|从小到大", text, re.IGNORECASE):
            result.add(("sort_direction", "ascending"))
        if re.search(r"\bcomment\b|注释", text, re.IGNORECASE):
            result.add(("code_form", "comment"))
    return result


def content_kind(entry):
    text = entry["text"].strip()
    if EMAIL.fullmatch(text):
        return "email"
    if URL.fullmatch(text):
        return "url"
    if re.fullmatch(r"#[0-9a-f]{3}(?:[0-9a-f]{3})?(?:[0-9a-f]{2})?|rgba?\([^\n]+\)", text, re.IGNORECASE):
        return "color"
    if re.fullmatch(r"\+?[0-9][0-9 ()-]{5,24}[0-9]", text) and 7 <= sum(c.isdigit() for c in text) <= 18:
        return "phone"
    if re.match(r"(?:/|~/|[a-z]:[\\/]|file://)", text, re.IGNORECASE) and "\n" not in text:
        return "path"
    if entry["kind"] in {"code", "command", "image", "file"}:
        return entry["kind"]
    if re.match(r"(?:\$\s*)?(?:git|npm|pnpm|yarn|python3?|curl|ls|cd|brew|swift|xcrun|docker|kubectl|ssh|rg|grep|cat|make)\s", text):
        return "command"
    return "text"


@dataclass
class Features:
    entry: dict
    index: int
    kind: str
    capabilities: set
    terms: set
    entities: set
    environments: set
    purposes: set

    def supports(self, kind):
        if kind == "image":
            return "image" in self.capabilities
        if kind == "file":
            return "file" in self.capabilities
        if kind == "path":
            return self.kind == "path" or "file" in self.capabilities
        return kind == self.kind and bool({"text", "richText"} & self.capabilities)


@dataclass
class Intent:
    required_kind: str | None
    wanted_kinds: set
    rejected_kinds: set
    terms: set
    negative_terms: set
    entities: set
    environments: set
    rejected_environments: set
    purposes: set
    has_context: bool


def extract_features(entries):
    result = []
    for index, entry in enumerate(entries):
        text = unquote(entry["text"])
        environments, _ = signed_labels(text, ENV_PATTERNS)
        purposes, _ = signed_labels(text, PURPOSE_PATTERNS)
        result.append(Features(entry, index, content_kind(entry), set(entry["capabilities"]),
                               terms(text), entities(text) | structural_entities(text, candidate=True), environments, purposes))
    return result


def field_constraint(context):
    surface = context["inputSurface"]
    if surface in SURFACE_KIND:
        return SURFACE_KIND[surface]
    label = normalized(context["fieldLabel"]).strip(" :：*")
    # A short metadata label can constrain format. Sentences and negative requests cannot.
    if not label or len(label) > 70 or NEGATION.search(label):
        return None
    patterns = {
        "email": r"(?:e-?mail(?: address)?|recipient|to|cc|bcc|收件人|邮箱|邮件地址)",
        "url": r"(?:(?:webhook|callback|api|website|homepage|documentation|staging|production)\s+)*(?:url|uri|web address)|网址|链接|接口地址",
        "phone": r"(?:(?:mobile|telephone|phone)(?: number)?|手机号|电话号码)",
        "path": r"(?:(?:file|folder|directory) path|文件路径|目录路径)",
        "color": r"(?:(?:hex |rgb )?colou?r(?: value| code)?|颜色值|色值)",
    }
    return next((kind for kind, pattern in patterns.items() if re.fullmatch(pattern, label)), None)


def make_intent(context):
    label = context["fieldLabel"]
    task = " ".join(context[key] for key in ("selectedText", "surroundingText"))
    combined = label + " " + task
    kinds, rejected = signed_labels(combined, KIND_PATTERNS)
    environments, rejected_envs = signed_labels(combined, ENV_PATTERNS)
    purposes, _ = signed_labels(combined, PURPOSE_PATTERNS)
    clean = positive_text(combined)
    negatives = terms(combined) - terms(clean)
    return Intent(field_constraint(context), kinds, rejected, terms(clean), negatives,
                  entities(clean) | structural_entities(clean), environments, rejected_envs, purposes,
                  bool(combined.strip() or field_constraint(context)))


def score_candidates(features, intent, signals=None):
    signals = signals or {}
    frequency = Counter(term for feature in features for term in feature.terms)
    count = len(features)
    ranked = []
    for feature in features:
        compatible = intent.required_kind is None or feature.supports(intent.required_kind)
        common = feature.terms & intent.terms
        lexical = min(7.0, sum(0.6 + math.log((count + 1) / (frequency[t] + 1)) for t in common))
        exact = feature.entities & intent.entities
        candidate_text = normalized(feature.entry["text"]).strip()
        exact |= {(kind, value) for kind, value in intent.entities
                  if (kind == "literal" and value in candidate_text)
                  or (kind == "prefix" and candidate_text.startswith(value))}
        typed_conflicts = sum(
            1 for kind, value in intent.entities
            if any(other_kind == kind for other_kind, _ in feature.entities)
            and (kind, value) not in feature.entities
            and kind not in {"url", "email"}
        )
        negative = min(5.0, 1.8 * len(feature.terms & intent.negative_terms))
        wanted = bool(intent.wanted_kinds and any(feature.supports(k) for k in intent.wanted_kinds))
        rejected = any(feature.supports(k) for k in intent.rejected_kinds) and not wanted
        evidence = lexical + (5.0 if exact else 0.0) - 4.5 * typed_conflicts - negative
        evidence += (4.0 if compatible else -12.0) if intent.required_kind else 0.0
        evidence += 2.4 if wanted else (-1.5 if len(intent.wanted_kinds) == 1 else 0.0)
        evidence -= 6.0 if rejected else 0.0
        if len(intent.environments) == 1 and feature.environments:
            evidence += 3.5 if feature.environments & intent.environments else -4.5
        if feature.environments & intent.rejected_environments:
            evidence -= 5.0
        if len(intent.purposes) == 1 and feature.purposes:
            evidence += 2.0 if feature.purposes & intent.purposes else -2.0
        model = 0.0
        kind_probs = signals.get("kind", {})
        supported = [probability for kind, probability in kind_probs.items() if feature.supports(kind)]
        if supported:
            model += 1.5 * max(supported)
        for name, values in (("environment", feature.environments), ("purpose", feature.purposes)):
            probabilities = signals.get(name, {})
            ordered = sorted(probabilities.values(), reverse=True)
            if values and ordered and ordered[0] >= 0.6 and (len(ordered) < 2 or ordered[0] - ordered[1] >= 0.18):
                model += 2.0 * max((probabilities.get(value, 0) for value in values), default=0)
        score = evidence + model
        strong_match = bool(exact or common or wanted or intent.required_kind or feature.environments & intent.environments)
        reason = ("匹配当前输入位置与语境" if strong_match else
                  "Laya 判断符合当前输入需求" if model else "匹配依据不足")
        ranked.append({"feature": feature, "score": score, "evidence": evidence, "model": model,
                       "compatible": compatible, "common": common, "exact": exact,
                       "conflict": bool(typed_conflicts or rejected), "reason": reason})
    # Recency only breaks equal scores; it is never recommendation evidence or a margin.
    return sorted(ranked, key=lambda row: (-row["score"], row["feature"].index))


def preselect(features, intent):
    ranked = [row for row in score_candidates(features, intent) if row["compatible"]]
    if not ranked:
        return []
    limit = 6 if intent.required_kind or intent.entities or len(intent.wanted_kinds) == 1 else 10
    if not intent.has_context or ranked[0]["evidence"] < 1.5 or len(ranked) <= limit:
        return [row["feature"] for row in ranked]
    cutoff = max(ranked[limit - 1]["evidence"], ranked[0]["evidence"] - 5.0)
    selected = {row["feature"].entry["id"] for row in ranked
                if row["evidence"] >= cutoff - 0.001 or row["exact"]}
    selected.update(row["feature"].entry["id"] for row in sorted(ranked, key=lambda r: r["feature"].index)[:2])
    return [feature for feature in features if feature.entry["id"] in selected]


def useful_facets(features, intent):
    result = []
    if len(set().union(*(f.environments for f in features))) >= 2 and len(intent.environments) != 1:
        result.append("environment")
    if len(set().union(*(f.purposes for f in features))) >= 2 and len(intent.purposes) != 1:
        result.append("purpose")
    return result[:2]


def decide(ranked, intent, signals):
    if not intent.has_context:
        return None, "insufficient_context", "当前语境不足 · 按复制时间排列"
    if not ranked:
        return None, "no_compatible_candidate", "没有符合输入格式的记录 · 按复制时间排列"
    top = ranked[0]
    feature = top["feature"]
    if not top["compatible"] or top["conflict"] or top["evidence"] < 0:
        return None, "no_compatible_candidate", "没有找到足够相关的记录 · 按复制时间排列"
    # Specific requests cannot be satisfied solely by a matching format.
    entity_groups = {kind for kind, _ in intent.entities}
    if entity_groups and not top["exact"]:
        return None, "no_compatible_candidate", "记录未匹配所需内容 · 按复制时间排列"
    kinds = signals.get("kind", {})
    model_kind = max(kinds, key=kinds.get) if kinds else "unknown"
    model_evidence = kinds.get(model_kind, 0) >= 0.65 and feature.supports(model_kind)
    substantive = bool(top["common"] or top["exact"] or intent.required_kind
                       or any(feature.supports(kind) for kind in intent.wanted_kinds))
    if not substantive and not model_evidence:
        return None, "insufficient_context", "匹配依据不足 · 按复制时间排列"
    if top["score"] < 1.0:
        return None, "insufficient_context", "匹配依据不足 · 按复制时间排列"
    if len(ranked) > 1:
        second = ranked[1]
        # Equal image/file summaries say nothing about their underlying bytes. Only text-only
        # representations can be considered interchangeable without inspecting raw payloads.
        other = second["feature"]
        identical = (bool(normalized(feature.entry["text"]).strip())
                     and normalized(feature.entry["text"]).strip() == normalized(other.entry["text"]).strip()
                     and "text" in feature.capabilities and "text" in other.capabilities
                     and not ({"image", "file"} & (feature.capabilities | other.capabilities)))
        if top["score"] - second["score"] < 0.85 and not identical:
            return None, "ambiguous", "几条记录都可能合适 · 请自行选择"
    return feature.entry["id"], "recommended", None


def public_rankings(ranked):
    return [{"id": row["feature"].entry["id"], "score": round(row["score"], 6), "reason": row["reason"]}
            for row in ranked]
