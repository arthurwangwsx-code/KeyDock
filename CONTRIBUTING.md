# 参与开发

先读 AGENTS.md 和 docs/status.md。本仓库已有第一阶段实现预览。核心测试、原生 App 构建和实际 Mac/API 验收分开记录，不把单测或文档校验当作完整日用验收。

## 环境与初始化

规划工具使用 Python 3 标准库、Git 和 iSpec 1.0.20（本次已验证）。当前编译验证工具链为 Xcode 27.2、Xcode Swift 6.4.2、XcodeGen 2.43.0；部署目标 macOS 14、当前实机 macOS 27.2/arm64。最低系统与 Intel 尚未验收。请使用 xcrun swift，PATH 的 Swift 6.3.3 与当前 SDK 不兼容。

```sh
git status --short
git branch --show-current
git worktree list
./scripts/new-feature-branch.sh feature/launcher-foundation
python3 scripts/validate-docs.py
```

新环境如需 iSpec skills，在确认已安装 CLI 后运行：

```sh
ispec init . --tools codex --language zh-CN --profile core --default-agent codex --no-telemetry --no-interactive
ispec status --stage artifacts --change keydock-foundation --json
```

新建开发分支必须使用 new-feature-branch.sh，从干净 master 的精确 HEAD 创建；禁止从其他 feature 分支起步。check-branch-policy.sh 仅检查当前分支名、单 checkout 和包含 master，不能独立证明创建来源；既有分支需另查历史与未合并差异。

生成的 .codex/skills 属本机工具，不进入提交。iSpec 配置和 change 文档进入仓库；内部状态通过 CLI 管理。

## 开发循环

1. 查当前需求/任务与 master 差异，保护 WIP，使用一个 checkout、一个写入者。
2. 更新 iSpec 行为场景和技术方案；先写最小闭环，再扩功能。
3. 模型、排序、执行策略用合成测试；OS 权限、快捷键、窗口、焦点和 Provider 联调用对应真机/真实 API 验收。
4. 用 pathspec 只暂存自己的文件，提交到命名分支；评审通过后 `git merge --ff-only <branch>` 晋升 master。
5. 发布另行处理。任何 push/publication 不因存在 remote 或 token 自动获得授权。

不引入个人数据 fixture。崩溃报告、网络诊断和 Agent trace 在共享前脱敏。

## 构建与测试

```sh
./scripts/build-app.sh
xcrun swift test
xcrun swift run -c release KeyDockDiagnostics
python3 scripts/update-localizations.py --check
```

XcodeGen 根据 project.yml 生成忽略的 KeyDock.xcodeproj，根 Package.swift 定义模块。不要复制 checkout 或清空构建目录解决常规问题。

`./scripts/build-app.sh --safe-smoke` 在构建产物 Info.plist 标记隔离测试模式：使用临时数据目录，禁用真实选区/窗口/剪贴板采集，不读取真实模型密钥。该模式只用于 UI 冒烟测试，不能作为真实系统能力验收。普通 build 会清除此模式标记。

HTTPIntegrationTests 使用 Python 标准库服务和动态 loopback 端口，全部数据为合成，不调用云服务。外部模型联调和20条质量样本待用户配置后另做；不得用 mock/local fixture 代替。

未配置开发者签名时 build-app.sh 产出 ad-hoc 签名本地 Debug App，不具备公证与公开分发资格。暂不自动安装到 /Applications，也不推送远端。
