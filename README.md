# PasteWhat

**下一次粘贴，刚刚好。**

一个纯 AppKit 界面的 macOS 菜单栏剪贴板工具。结合应用类别、输入框语境与 **Laya 本地模型**或可选 **Jev 云端模型**，从最近 10 条记录中推荐此刻需要的内容，并放在首位；完整历史照常展示与搜索。

Native AppKit clipboard history with contextual Laya recommendations and an opt-in Jev API backend.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pastewhat-dark.jpg">
  <img src="docs/assets/pastewhat-light.jpg" alt="PasteWhat 原生剪贴板面板：Laya 推荐、搜索、完整预览和粘贴操作" width="780">
</picture>

截图使用隔离的合成演示内容，推荐由真实本地模型产生。

## 可以做什么

- 常驻菜单栏，`⌥⇧V` 打开；快捷键可更换。
- 记录最近 **20 条不同的复制内容**，重复内容更新到最新位置。
- 支持文本、链接、邮箱、代码、命令、颜色、PNG/TIFF、文件 URL 和常见富文本表示。多文件复制作为一条记录保留；单条所有表示合计最多 8 MiB。
- 打开时锁定目标应用，再读取可用的聚焦输入框语境；不抓屏。
- 后台先预筛候选，推荐项置首；前端仍保留完整历史，其余记录维持复制时间顺序。开始选择后，异步推荐不会换掉选中的条目。
- 搜索内容、来源和类型；查看文字或图片预览；复制原格式或纯文本，粘贴回原应用。
- 浅色、深色、跟随系统；可暂停记录、删除记录、清空历史、关闭磁盘保存和启用登录启动。

推荐只改变面板顺序。**选择复制或粘贴后才会修改系统剪贴板。** 历史从应用运行期间开始积累，无法取回 macOS 从未保存的过去 20 次复制。

## 安装

需要 Apple silicon Mac、macOS 14+。本地推荐通过系统 Python 3 运行（安装 Xcode 命令行工具后即可用）；模型未安装时自动退化为本地匹配，面板会明确显示，历史、搜索和手动复制粘贴不受影响。

**Homebrew（推荐）**

```bash
brew trust mizorewww/tap   # Homebrew 7+ 首次从第三方 tap 安装 cask 时需要
brew install --cask mizorewww/tap/pastewhat
```

**手动下载**：从 [GitHub Releases](https://github.com/mizorewww/pastewhat/releases) 下载 `PasteWhat-<版本>.zip`，解压后把 `PasteWhat.app` 拖进「应用程序」。发布版本经过 Apple 公证并 staple，首次打开可直接通过 Gatekeeper。

首次启动后点击菜单栏图标 → 设置 →「开启辅助功能…」，在系统设置中允许 PasteWhat（用于读取聚焦输入框语境和自动发送粘贴）。没有权限时仍可记录、浏览、搜索和复制，手动 `⌘V` 粘贴。

安装本机 Laya 模型（可选，首次下载约数百 MB，之后强制离线运行，需要 [uv](https://docs.astral.sh/uv/getting-started/installation/)）：

```bash
/Applications/PasteWhat.app/Contents/Resources/setup-engine.sh
```

升级与卸载：`brew upgrade --cask pastewhat`、`brew uninstall --cask pastewhat`。

## 构建与运行

需要 Apple silicon Mac、macOS 14+、带 Swift 6 的 Xcode 16.3+。可选 Core ML 后端需要 macOS 15+。当前在 M3 Max、macOS 27.2、Xcode 27.0 上完成构建与运行验证。

```bash
git clone https://github.com/mizorewww/pastewhat.git
cd pastewhat
./scripts/build-app.sh
open dist/PasteWhat.app
```

生成 `dist/PasteWhat.app`，默认进行本地 ad-hoc 签名。可用 `./scripts/build-app.sh debug` 构建调试版，也可以在 Xcode 中打开 `Package.swift`。长期使用请启动 `.app`，以获得稳定的菜单栏、权限和登录启动行为。

仓库根目录的 Makefile 提供常用开发目标：`make build`、`make install`（安装到 `~/Applications`，可用 `INSTALL_DIR` 覆盖）、`make check`（构建 + ruff + 语法检查）、`make lint` / `make fix` / `make format`（ruff）、`make evaluate`（按 `engine.json` 的配置跑冻结评估）、`make demo`、`make clean`。`make help` 查看全部。

### 本地 Laya 引擎

界面和系统集成都由 Swift/AppKit 实现；推理由一个**常驻 Python worker** 复用已验证的 Laya runtime。模型只加载一次，同一语境会复用类型推理结果。

如果本项目与 `laya-mlx` 位于同一父目录，应用会自动发现其 `.venv/bin/python` 和 `models/hub/laya-multilingual-mlx`。也可在设置中选择已有 Python 和模型。

独立安装需要 [uv](https://docs.astral.sh/uv/getting-started/installation/)：

```bash
# 默认 MLX：创建 Python 3.12 环境、安装 runtime、下载 multilingual 模型
./scripts/setup-engine.sh

# 已有权重，跳过下载
./scripts/setup-engine.sh --model /absolute/path/to/laya-multilingual-mlx

# 复用 sibling 项目，既不安装也不修改 sibling
./scripts/setup-engine.sh --use-sibling

# 可选通用 Core ML multilingual（CPU + GPU）
./scripts/setup-engine.sh --backend coreml
```

安装配置位于 `~/Library/Application Support/PasteWhat/engine.json`。安装后重新启动应用；在设置中修改路径后点击“保存并重新连接”即可。模型不包含在 Git 仓库或 `.app` 中。首次下载约数百 MB；Laya 后端强制离线运行，不上传剪贴板或语境。

Core ML 请使用通用 `laya-multilingual-coreml`，不能使用 96-token 的 ANE 模型。它的短请求速度数据不适用于这个产品的上下文任务。更多说明见 [引擎文档](docs/ENGINE.md)。

### Jev 云端引擎

在设置中选择 **Jev · 云端**，填入 [TypeSafe API Key](https://docs.typesafe.ai/introduction/quickstart)，点击“保存并重新连接”。已有 Python 3 即可运行此后端，不需要下载 Laya 权重。密钥保存在本机 `credentials/jev.key`，目录权限 `0700`、文件权限 `0600`；可以在设置中移除。CLI 也支持 `TYPESAFE_API_KEY` 环境变量。

启用后，应用类别、输入框附近文字及预筛候选摘要会发送到 `api.typesafe.ai`；不发送真实应用身份、原始图片或文件数据。列表仍展示全部历史。请求失败会保留时间顺序，界面明确区分云端推荐与本机推荐。API 使用 `jev-latest`，实际返回版本记录在评估结果中。

首轮 120 例合成回归中，Jev 的推荐精度为 **74/75（98.67%）**、覆盖率 **75/120（62.50%）**，可推荐样例实际命中 **74/97（76.29%）**；并非“整体准确率 98.67%”。同一全量集合上原本地流程命中 77/97，说明当前 Jev 阈值更保守。详见 [Jev 回归报告](evaluations/JEV.md)。

专用本地学生模型的训练工程与独立评估在 [PasteWhat-Ranker-v1](https://github.com/mizorewww/pastewhat-ranker-v1)，发布状态以该仓库和模型卡为准。

### 系统权限

辅助功能权限用于读取聚焦输入框和自动发送粘贴快捷键。点击应用设置中的“开启辅助功能…”，在系统设置里允许 PasteWhat；重新打开面板即可检测。没有权限时仍能记录允许读取的剪贴板、浏览历史、搜索和复制，然后手动 `⌘V`。只有应用类别而没有有效输入语境时，保留时间顺序。Chrome 等 Chromium/Electron 应用只在有辅助功能客户端时才会暴露网页内容；PasteWhat 打开面板时会自动请求启用，首次约需两秒，之后该应用本次运行期间都有效。

macOS 15.4+ 还可能单独询问剪贴板读取权限。持续记录需要允许 PasteWhat 访问剪贴板；拒绝时底栏会显示原因。应用不需要屏幕录制权限。开发时重新签名可能需要系统重新确认辅助功能权限。

## 操作

| 操作 | 快捷键 / 入口 |
|---|---|
| 打开或关闭面板 | `⌥⇧V`，或点击菜单栏图标 |
| 选择记录 | `↑` / `↓` |
| 粘贴所选记录 | `↩`，或双击记录 |
| 复制所选记录 | `⌘C` / `⌘↩` |
| 复制纯文本 | `⌘⇧C` / `⌘⇧↩` |
| 粘贴前九条中的指定记录 | `⌘1` … `⌘9` |
| 搜索 | 直接输入，或 `⌘F` |
| 删除记录 | 垃圾桶按钮；列表聚焦时可 `⌘⌫` |
| 关闭面板 | `Esc`，或点击外部 |
| 设置 | 齿轮 / `⌘,` |
| 暂停、退出 | 右键菜单栏图标 |

文字选区的 `⌘C` 保留正常复制行为，搜索框的 `⌘⌫` 保留正常文字编辑行为。输入法有未确认文字时，回车和方向键优先交给输入法。

## 推荐如何工作

Laya 与 Jev 都只选择既有内容，不生成粘贴文本。Swift 先把真实应用映射为浏览器、开发工具、终端、邮件等类别；模型请求中不包含应用名称、bundle ID、PID 或完整窗口标题。输入框和光标附近的语境优先于应用类别，真实应用信息保留在界面与粘贴目标校验中。

有辅助功能权限时，语境包含实际选区两侧的文本；读取不到光标位置时明确标记未知。还会在同一父容器内读取至多 4 条临近静态说明，不读取其他输入框的值。选区按系统 UTF-16 偏移处理；不会把文本中的填空符号当成已选中的位置。模型训练的数据投影复用这一格式。

后台根据格式能力、明确字段约束、实体和文字匹配预筛候选，保留命令参数、否定条件与内容结构。候选数量自适应；证据不足时可保留全部送入记录。再结合 Laya 的类型和按需语义判断排序。新近度只用于同分时排序，不能单独构成推荐依据；没有明确答案或多个候选接近时不强行置顶。只有最近 10 条记录进入推荐；前端列表、搜索和手动粘贴始终覆盖完整历史。

Jev 后端对同一预筛候选进行一次结构化选择，包含弃权选项。它的置信度门槛是未经本产品校准的保守歧义门槛，不承诺固定正确率。

模型概率不作为“推荐正确率”展示。早期 4 个样例仅用于探索，现有独立合成数据、冻结哈希、真实模型对照和无模型消融见 [推荐评估](evaluations/README.md)。合成评估不能替代真实用户使用效果。

模型未就绪时明确显示本地匹配或按时间排列。安全输入框会暂停语境推荐；原应用退出、焦点切换或剪贴板在操作期间变化时会取消自动粘贴，避免粘贴到错误的地方。

## 本地数据

历史保存在 `~/Library/Application Support/PasteWhat/history.json`，目录权限 `0700`、文件权限 `0600`，原子替换；退出前等待保存完成。它是本地文件保存，并非加密保险箱。关闭“在本机保留最近 20 条记录”会删除磁盘历史，当前会话仍可使用内存记录。

应用跳过带 concealed/transient/autogenerated 标记的内容和已知密码管理器来源。不应把这种尽力排除视为对所有敏感内容的保证。原始内容和格式用于粘贴，推荐只使用有界摘要和当前输入语境。

## 验证与开发约定

先查文档和 sibling 实现，再记录 [设计决策](docs/DESIGN.md)，不做 TDD。实现稳定后进行构建、真实模型、协议、存储和界面验证；临时验证脚手架均删除，没有测试 target 或合成测试数据混入真实历史。

[验证记录](docs/VALIDATION.md) 包含环境、实际完成的检查和未覆盖的范围。界面可独立演示：

```bash
open -n dist/PasteWhat.app --args --demo
```

演示不读取、保存或删除真实历史，但用户主动点击复制会复制示例内容。正常启动不填充任何示例。

构建脚本按以下顺序选择签名身份：`PASTEWHAT_SIGNING_IDENTITY` 环境变量 → 钥匙串中的 **Developer ID Application** → `make signing-identity` 创建的本地自签名身份 → ad-hoc（并打印警告）。默认的 ad-hoc 签名每次构建都会改变 cdhash，macOS 的辅助功能、剪贴板等授权与签名绑定，因此每次重装都会静默失效；任何稳定身份都能让授权跨构建保留。钥匙串中已有 Developer ID 时无需任何操作；没有 Apple 证书的机器执行一次 `make signing-identity` 即可（有效期十年，首次签名若询问是否允许 codesign 使用密钥，选择“始终允许”）。

对外分发：`make notary-profile KEY=/path/AuthKey_XXXX.p8 KEY_ID=... ISSUER=...` 存入 App Store Connect API 凭证（一次），之后 `make release` 以分发模式构建（不嵌入本机 workspace 路径）、公证并 staple，打包出版本化的 `dist/PasteWhat-<版本>.zip` 与 sha256，可直接作为 GitHub Release 资产。只需公证不打包时用 `make notarize`。

模型和 runtime 来源见 [NOTICE](NOTICE)。
