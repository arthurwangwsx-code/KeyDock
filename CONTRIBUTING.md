# 参与开发

先读 AGENTS.md 和 docs/status.md。本仓库当前为方案仓库，没有 Swift App、可运行构建或产品测试命令；不要把文档校验当作应用验收。

## 环境与初始化

规划工具使用 Python 3 标准库、Git 和 iSpec 1.0.20（本次已验证）。后续建议 Swift 6 / Xcode 16 或更新版本、macOS 14+；确切工具链和部署矩阵在 P0 编译后锁定。

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
