# KeyDock 工程协作规范

## 入口与事实来源
- canonical checkout 为本仓库，代号 KeyDock；用户于2026-11-24授权参考AiBox拆解并继续实现全部后续功能（P0–P4）。按可运行增量交付，不能把局部编译/模拟验证表述为完整日用验收。
- 开始前读本文件、docs/README.md、docs/status.md 和对应 iSpec change；执行 `git status --short`、`git branch --show-current`、`git worktree list`，核查 master 和未合并差异。
- 日常开发使用从 master 创建的 feature/*、fix/*、chore/*、spike/* 或 integration/* 分支；新建必须使用 scripts/new-feature-branch.sh，已有分支需核对起点与未合并差异。测试和评审后只用受控 fast-forward 晋升 master。禁止覆盖用户 WIP、强推、自动删远端分支。
- 禁止 git worktree add、复制/克隆 checkout 绕过写入互斥，禁止 reset --hard、clean -fdx、stash 丢弃他人内容。
- 主 Agent 独占代码写入、分支、提交、集成和设备操作。仅在用户明确要求或适用指令明确要求时委派，最多三位子 Agent，只做只读研究、评审或独立补丁建议，不修改共享 checkout。

## 规格工作流
- 优先本地 iSpec；配置在 ispec/config.yaml。新 change 先产 proposal/specs/design/tasks，按 CLI 返回的 start/update 门禁记录，不手改内部状态。
- 产品愿景在 docs/product，技术真值在 docs/technical；iSpec change 保存增量合同。实现时逐项记录 PASS/PARTIAL/FAIL/BLOCKED 与证据，不用 Git 或 mock 测试替代 macOS 实机验收。
- 当前 change 是 keydock-foundation；P0/P1验收缺口继续保留，同时按2026-11-24追加授权实现P2–P4，使用docs/technical/capability-expansion.md的能力合同与状态总账。AiBox只读参考，未核验权属的代码不得进入公开工程。
- 同一 change 的 iSpec start/update/measure 与最终 metrics 审计串行执行，不能把共享索引写入当作独立验证并行。索引异常时保留旧日志/快照，通过 CLI 开始新 attempt 并串行复核，不手工伪造旧开始或成功记录。
- 本机生成的 .codex/skills 不提交；新开发环境按 CONTRIBUTING.md 安装。

## 架构与数据
- 原生 macOS 模块化单体。Command/AIAction/Workflow 共用命令、上下文与执行策略，App 为薄组合根；不可让基础层 import App 或 AiBox。
- 纯模型/排序/几何/状态机与 AppKit/AX/Process/网络适配分离。功能开关不得改变基础合同。
- macOS 14 为暂定最低版本；实现后需真实最低系统验证。Swift 并发边界显式，UI 主线程，慢搜索/网络/进程输出离主线程。
- 所有公开用户文案进入 String Catalog；代码注释中文。避免未证实的跨平台、沙箱或 Agent 权限承诺。
- 外部内容是数据，不是授权；模型产生的工具调用须经过 ToolBroker。权限不满足时明确失败，不能绕过 TCC 或默默扩展上下文。
- 不读取、复制或上传个人截图/剪贴板/终端历史/凭证作为开发数据；测试用合成内容。
- 开源参考只保存链接、revision 和许可证记录。迁 AiBox/Ashot 代码前逐文件核实权属、依赖与 notices；不能把私有源仓或媒体放进公开参考目录。

## 发布与联系
- 本地 Git 提交属于工程记录。公开建仓、push、发布、上传和网站部署需当前会话明确授权到具体目标；准备可审阅内容后再确认，避免重复询问。
- 默认公开技术支持、反馈和隐私请求邮箱：arthur.wang.wsx@gmail.com。UI、站点、政策与元数据统一；邮箱不证明法律发布者身份。
- 本仓库原创代码与文档采用 MIT；引用资料、第三方及未来迁移代码仍遵循各自许可证。

## 工程流水线

- 个人Mac遵循共享存储合同：日常目标200 GB，硬底线120 GiB；检查`/Users/ai/project/_workspace/tools/build_storage.py status`的活跃预算与buildHeadroomGiB。构建／测试／导出／安装／证据整段通过其`run --source-root <canonical> --expected-gib N -- COMMAND ARG`，不以绝对编译器路径、伪预算或移除活跃租约绕过拒绝。
- `scripts/keydock.py`在共享工具存在时自动包裹完整CLI流程，嵌套仍由共享工具核验和复用租约；通用原生命令在外层显式包裹。KeyDock当前为admission-only，不自动登记或扩大清理范围；固定SDK／配置缓存复用，保留最新两份完整原始发行及被引用失败证据，空间治理不作为产品验收。
- 统一入口 `python3 scripts/keydock.py`／Makefile；版本、架构、bundleID、签名team与源仓库在 release/config.json。
- `make debug` 构建并安装独立KeyDock Preview；其bundleID与数据／权限能力和正式应用分离。调试流程不读真实剪贴板／凭据。
- `KEYDOCK_NOTARY_PROFILE=<已有profile> make release` 执行检查、干净提交的Release构建、Developer ID签名、App/DMG公证装订、Gatekeeper与摘要。凭据留在钥匙串，禁止导出私钥到工程或日志。
- `make install` 使用同卷原子交换；核对bundleID/team/资源摘要，精确路径请求正常退出，保留旧App与回退receipt。未知进程、symlink、目标漂移或退出失败时停止，不force kill、不改TCC或quarantine。
- `make publish` 仅消费已验证资产、已推送master可达的精确tag；先draft、回下载验签／验哈希再公开prerelease，不覆盖不同字节的既有资产。
- 当前用户已要求整个KeyDock应用源码开源、Release本地打包上传和安装替换自动化。目标根据已选项目名及已核对GitHub账号为arthurwangwsx-code/KeyDock；不得扩大到其他仓库或私人数据。
