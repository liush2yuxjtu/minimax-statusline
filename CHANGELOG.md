## 0.2.2 — 2026-09-20

- Replace the package-specific usage sender with the shared `@nyn5255/telemetry@^0.1.3` SDK.
- Use the production collector by default after explicit telemetry opt-in and privacy acknowledgement.
- Align the funnel with `install → activated → first_success → d7_retained` plus `weekly_active`.
- Preserve `DO_NOT_TRACK` / `PI_TELEMETRY_DISABLED` handling through the shared SDK.

# 更新日志

`minimax-statusline` 的所有重要变更都记录在这里。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 和 [语义化版本](https://semver.org/lang/zh-CN/spec/v2.0.0.html)。

## [0.2.0] — 2026-06-03 · 改名

### 重大变更
- **项目改名**：`claude-statusline` → `minimax-statusline`，定位改成"专为 MiniMax CLI / Coding Plan"
- **GitHub repo**：`liush2yuxjtu/claude-statusline` → `liush2yuxjtu/minimax-statusline`
- **npm 包**：`@liushiyumathxjtu/claude-statusline` → `@liushiyumathxjtu/minimax-statusline`
  - 旧包 `@liushiyumathxjtu/claude-statusline@0.1.0` 已标记 deprecated
- **VS Code 扩展**：`liush2yuxjtu.claude-statusline` → `liush2yuxjtu.minimax-statusline`（新 ID，已重发）
- **Homebrew formula**：`Formula/claude-statusline.rb` → `Formula/minimax-statusline.rb`
- **脚本**：`statusline.sh` → `minimax-statusline.sh`
- **CLI / bin 名**：`claude-statusline` → `minimax-statusline`
- **本地目录**：`~/claude-statusline` → `~/minimax-statusline`

### 用户可见的文案
- 落地页 README、CHANGELOG、docs/、落地页 (`web/app/page.tsx`)、Vercel 部署 — 全部汉化
- "Claude Code" 在所有 prose 中改为 "MiniMax CLI"
- 关键词 `claude-code` 改为 `minimax`

### 未变
- stdin JSON 合同（仍读 CLI 注入的 JSON，键名 `cwd` / `model` / `effort` / `context_window` 不变）
- 用户级配置目录仍是 `~/.config/statusline/`（向后兼容）

### 升级指引
```bash
# 1. 卸载旧版（如果你通过 npm / Homebrew 装过）
npm uninstall -g @liushiyumathxjtu/claude-statusline
brew uninstall liush2yuxjtu/tap/claude-statusline

# 2. 装新版
brew install liush2yuxjtu/tap/minimax-statusline
# 或：npm install -g @liushiyumathxjtu/minimax-statusline
# 或：git clone + ./install.sh

# 3. ~/.config/statusline/config.toml 不用动，配置格式没变
```

## [0.1.0] — 2026-06-03 · 首次公开

### 新增
- 首次公开发布
- 重构后的 bash 状态条脚本：~250 行，模块化（`lib/parse_input.py` + `lib/fetch_plan.py`）
- 通过 TOML 配置（`~/.config/statusline/config.toml`）；见 `config.example.toml`
- 可插拔的提供方系统（`minimax` / `none` / `custom`），60 秒写入式缓存
- 四套自带主题：`default` / `minimal` / `vivid` / `solarized`
- 布局配置：选要显示哪些段、顺序怎么排
- CLI 参数：`--version` / `--help` / `--doctor` / `--dump-config` / `--self-test` / `--init-config`
- 自带 `install.sh` + `uninstall.sh`（幂等，可重复跑）
- 零依赖的 stdlib-only TOML 解析器（`lib/tiny_toml.py`）
- 测试：pytest（Python）+ bats（shell）+ shellcheck
- CI：GitHub Actions 每次 push 跑 shellcheck + bats + pytest
- VS Code 扩展（在 `bin/vscode-extension/`）把脚本结果镜像到 VS Code 状态栏
- npm 包装器，跨平台安装
- Homebrew formula 在 `liush2yuxjtu/homebrew-tap`
- Vercel 落地页

### 相对原个人脚本的修复
- `date +%3N` 在 macOS 上静默坏掉 → 改用可移植的 Python 时间戳
- `eval` 未转义 Python 输出有注入风险 → 改用类型化管道
- 空 git 仓库的分支从 `-` 改为 `(empty)`
- API 错误按类型分桶（`no-token` / `net` / `auth` / `http-N` / `generic`），按主题色渲染
- API 响应缓存 60 秒，状态条不再每次刷新都打提供方
- token 环境变量名可配置
