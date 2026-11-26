# KeyDock 多Agent并行续接提示词

将下面内容交给新的主Agent执行。它是后续调度提示词，本次收口没有开启新一轮开发。

```text
继续完成 KeyDock 原有完整P0–P4目标，不把目标缩成当前已通过的子集。你是主Agent，可并行协调最多3位只读子Agent。

工程与现状：
- canonical checkout：/Users/ai/project/macOS/KeyDock；GitHub：arthurwangwsx-code/KeyDock。
- 正式安装／公开发行仍是已公证alpha.27，代码e6c7b98；master文档基线eb4b506。首先实时核对，不沿用旧状态。
- 当前fix/usage-retention-budget-redaction分支保存尚未发行的自动清理实现。先读docs/implementation/usage-retention-handoff-2026-11-26.md，查看当前HEAD、未提交差异及CI。
- 当前本机1094 Swift执行／156 Python／1035中英key、合成OCR双轮及定向44项通过；检查时工作区未提交。它不是最终clean提交、优化Preview、原生或发行资格。

开始前：
1. 阅读AGENTS.md、docs/README.md、docs/status.md、docs/product/quick-actions-completion.md、docs/technical/remaining-engineering-2026-11-26.md、docs/technical/usage-restoration-fence.md和当前iSpec keydock-foundation。
2. 执行git status --short、git branch --show-current、git worktree list，核对master、当前分支与待集成变更；遵循既有iSpec start／measure／metrics工作流。
3. 全部构建／测试／导出／安装／证据流程用共享build_storage.py gate，诚实预留峰值预算。目标200 GB、硬底线120 GiB；保留最新两份完整raw及引用的失败／回退证据。

并行分工：
A：AI与执行正确性审查。只读审查当前43／42.4差异，优先找延后预算和clear意图在owner收口、shutdown、重启的缺口；当前票据仅进程内。审查Workflow父子摘要、真实worker新事实、失败事务和候选身份。再给费用停止阈值、持久步骤、原图附件及增量用量的优先补丁建议与验收方案。模型／费率研究只用官方来源并标日期。
B：快捷操作与日用闭环审查。对照规格核对独立剪贴板热键面板、历史查询、键盘选择、有序多条合并、准确一次插入、目标变化／取消／权限撤销、应用／窗口控制和自定义快捷键。按生产调用路径列缺口及真实验收步骤，区分实现、合成宿主与正式身份的证明。
C：交互与视觉／配置审查。以交互和视觉设计师视角审查独立Launcher／Settings／Workspace及菜单栏入口、原生Liquid Glass、最小／常规窗口、中英深浅、长文本、首次布局、焦点、IME、VoiceOver、多屏及系统对比度／透明度／动态设置。核查默认／九类场景／动作／Agent模型覆盖、思考与输出上限、推荐目录日期及服务模型清单，研究竞品时保留官方来源。

三位子Agent都不修改共享checkout、不切分支、不运行构建／测试、不操作App或设备、不提交／推送；只返回文件行号、证据、风险、优先级和独立补丁建议。主Agent汇总后独占串行实现、测试、设备、Git和集成。禁止worktree、复制checkout、stash、reset --hard、clean -fdx、强推或自动删远端分支。新分支只能由master通过scripts/new-feature-branch.sh创建，不能从当前feature再分叉。

主Agent执行顺序：
1. 先把当前fix分支收口到可发行资格：解决实证问题、冻结最终源码、完整本机／同源CI／优化Preview、owned合成原生启动维护与双语部分失败显示。42.4／43未证明前不关闭。
2. 然后按产品价值串行推进费用停止阈值和其他明确工程缺口，并完成真实剪贴板／窗口／热键闭环；保持原完整P0–P4与竞品能力建设范围。
3. 同步完善产品、技术方案、使用说明和PASS／PARTIAL／FAIL／BLOCKED总账，每项证据绑定源SHA、App版本、身份、环境和验证范围；不以mock／绿测替代实际日用验收。
4. 只有测试与审查通过才受控fast-forward晋升master。沿用scripts/keydock.py流水线完成本地打包、Developer ID签名、公证／装订／Gatekeeper、精确tag、GitHub draft回下载校验后公开、正式App原子替换与回退receipt；native-review每次不可覆盖的证据和调试入口也要完成。不要复用旧tag或覆盖不同资产。

数据与授权：
- 仅合成输入／owned夹具／loopback作开发数据；AiBox /Users/ai/project/mobile-ios/AiBox只读参考设计，迁移代码须逐文件核权属与许可证，不公开私人源码或媒体。
- 真实API凭据仅留钥匙串，由正式App用合成数据联调；不从CLI／Agent提取、打印、重录或提交密钥。AI生成命令必须明确审批，重启不重放有副作用任务。
- 不绕过TCC；机器解锁不等于AX／录屏授权。既有Terminal／SecurityAgent拒绝不得重试绕过；待用户权限项单列，不重复索要已问过的确认。
- 保持公开支持／反馈／隐私请求邮箱arthur.wang.wsx@gmail.com。已授权目标仅此KeyDock仓库，不扩大到其他仓库、私人数据或消息发送。

最终交付须明确：本轮实际实现、验证及剩余项、干净提交与CI、正式安装版本、Release资产和回退位置。完整视觉、真实插入／实体键盘、最低系统、长期驻留及全部原目标未逐项证明前，不宣告整个项目完成。
```
