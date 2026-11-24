## Context

参考 [提案](10-proposal.md) 建立全新 KeyDock。用户要求原生快捷操作、可持续架构及外部 API AI，包含可绑定快捷键的翻译/总结、CLI 扩展、使用分析和通用 Agent。初始方案已进入P0/P1实施；2026-11-23追加开源、预发行和安装流水线。

## Goals / Non-Goals

**Goals:** 以统一命令/工具/上下文/执行模型承接桌面与 AI 动作；P1 可日用；各阶段有真实验收；选择性参考 AiBox 与公开项目。

**Non-Goals:** 不采集个人开发素材、不复制旧源码／凭据；首期不做全屏持续监控、扩展市场或完整Raycast兼容。公开范围按用户新增发行要求与治理文档执行。

## Decisions

- 原生 Swift 6 + AppKit Panel/SwiftUI，暂定 macOS 14；模块化单体，App 薄组合根。Electron/RN 方案推迟到确有跨平台需求。
- CommandCore/ExecutionCore/AICore 为纯合同；SearchEngine/AgentCore 通过 host seams 依赖 OS/模型/存储。统一执行服务避免各功能重复权限和取消逻辑。
- AIAction 直接调 ProviderGateway；只有多步工具任务才进入 AgentRuntime。Provider 独立适配，tool-call 总经 Broker，MCP 与 ACP 分别承担工具和外部 Agent 接入。
- 剪贴板、Activity、模型用量、任务正文分域保存，元数据优先。未知 usage/cost 不伪装为实测；保存动作可在已确认范围内一键运行。
- CLI executable/argv 与 shell/PTY 明确分开；窗口身份不能仅用 PID；查询采用 generation 防止陈旧结果覆盖。
- references 只登记 URL/revision/license，不 vendor 参考仓；AiBox portable 核心只作为后续抽取候选。

完整决策、合同、时序和状态机见 [架构](../../../docs/technical/architecture.md)、[AI 与自动化](../../../docs/technical/ai-and-automation.md)、[数据与权限](../../../docs/technical/data-and-permissions.md)。

## Risks / Trade-offs

- [macOS 权限/多屏/Space 行为不同] → P0/P1 做真机 spike，声明公开 API 能力边界。
- [云模型延迟、限流、重复计费] → 搜索隔离、超时/取消、有界重试，生成与执行分开。
- [第三方进程绕过 Broker] → 只允许可信显式启用来源，未验证 OS sandbox 不宣称权限隔离。
- [Agent 崩溃时副作用不确定] → intent/result 回执，unknown outcome 不自动重放。
- [迁移带入私有耦合或许可证问题] → 逐文件 provenance/notices；本轮不复制。

## Migration Plan

从空 master 的 feature/product-foundation 建立文档与 change，经校验与只读评审后 fast-forward master。P0 新建 Swift 工程；每个可迁模块单独 change，保留来源 revision。数据库首次实现即版本化迁移，失败可保留旧文件与前一发布包；没有数据转换或源码删除在本轮发生。

## Open Questions

第一个联调 provider/endpoint/model、最低系统真实验证设备、签名发布者和 App Sandbox 能力 spike 尚待实施前确定。名称 KeyDock 为用户接受代号。公开远端的具体仓库与范围在可审阅内容完成后确认。

## 2026-11-23 范围追加

用户明确要求完整应用GitHub开源、本地Release上传及本地安装替换流水线。当前追加release-engineering合同与任务8.x，技术细节以docs/technical/release-pipeline.md为准。master在编译／测试／审查通过后受控fast-forward，alpha发行与完整P1日用资格分别记录；其余P2–P4产品能力继续后置。签名凭据由系统钥匙串引用，公开源码与发行物不含私钥、API配置或个人数据。

## 2026-11-24 全部后续能力追加

用户明确要求参考AiBox继续实现全部后续功能。P2–P4进入实施范围，产品切片、技术合同和逐项验收见[后续能力方案](../../../docs/technical/capability-expansion.md)。第一阶段未完成的权限／物理快捷键／IME／外部API／质量／兼容性义务不变。采用设计借鉴与独立实现，当前没有迁移AiBox源码的许可receipt。

## 2026-11-25 URL动作编辑隔离

URL运行选择与编辑草稿分别由WorkspaceSession持有；Use和Launcher深链接只选择运行目标，Edit才加载固定编辑ID和完整字段。View重建或切换页面不把空表单配给旧运行ID。成功持久化后清空编辑身份与字段；验证或写入失败保留草稿，沿用配置事务补偿。携带编辑ID的保存只允许更新仍存在的动作，不能隐式重建已删除目标。原生验收只使用合成example.com地址，不打开浏览器。

集合沿用同一窗口会话原则，浏览ID与编辑草稿分离。commandIDs数组是唯一顺序真值，候选过滤只影响展示；勾选追加，前后移动或显式移除才改变顺序。缺失引用保持位置和容量，保存拒绝不可用／窗口／集合引用；用户显式清理后仍保留其余相对顺序。模型JSON格式不变，带ID更新拒绝已删除目标，保存事务失败完整保留草稿。编辑与保存没有批量运行语义。

## 2026-11-25 视觉抽样边界

隔离Preview使用独立环境键和持久宿主注入自有组件样例，不改变OS辅助功能偏好；仅编译／隔离标记／bundle／profile全部匹配时接受切换。有效设置保留系统真实需求，正式构建不能通过启动参数启用样例。26+材质只修饰背景，前景及会话保持在固定结构中；焦点／选区稳定必须原生复查。样例不是OS控件、VoiceOver、IME或完整视觉验收的替代品。

## 2026-11-25 AI配置前置体验

提取Provider的纯结构配置构造，供实际请求、界面和运行菜单复用；准备判断不读凭据、不联网。AI动作使用独立模型覆盖，CLI草稿／只读Agent使用全局配置。主要动作在配置无效时引导设置，运行中保留Stop；配置修改不启动新任务，也不改变旧结果交付权限。匿名服务不因未保存key误禁，真正认证和模型质量留待用户配置后的验收。

## 2026-11-25 工作流初始输入

在已编译计划上追踪初始输入依赖：变换传递依赖，AI和含完整输入占位参数的保存命令消费依赖；固定命令输出与人工输入形成屏障，最终输出仍有依赖时也需前置输入。快捷入口只传工作流ID到独立输入sheet，编辑稿／原输入和页面不变；普通工作流页的用户显式运行与App内计划合同不变。

每个输入呈现有独立UUID，取消／提交／重载均核对该身份。打开时不创建运行、不读剪贴板或凭据；提交时复核保存定义的完整值，修改须显式重载，删除不复活。引用的命令和AI配置仍在真正启动时按原执行宿主冻结，动态argv逐次审批保持不变。输入拒收超过131072 UTF8字节的编辑，保留旧内容并禁止运行，合法编辑后才解除；没有截断执行。

## 2026-11-25 定义保存反馈

Agent／工作流的工作区提交复用既有配置写入与补偿事务，失败消息同步到当前Workspace，成功才清除旧失败提示。会话保存入口只在持久化成功后回填真实定义版本，失败不改草稿、步骤或运行输入。保存状态从当前配置与编辑稿派生，区分未保存、存在修改及已保存版本；文本额外核对UTF8字节，导航和界面重建不产生旧成功提示。删除失败同样留在发起页，在途任务快照和执行宿主不受此次UI反馈改动影响。

保存命令与AI动作的移除采用独立审阅sheet，按类型化UUID图列出工作流／Agent／集合／计划引用；指纹与当前引用在最终确认同步重查，不做级联删除。原生发现刷新身份导致Esc失效后，呈现保持稳定ObservableObject身份，每次审阅另有UUID，取消按呈现、确认按当前快照绑定。定义及准确命令ID的快捷键、收藏、别名、最近项由既有注册／持久化补偿事务一次提交。设置编辑会话固定new／edit意图，被移除目标拒绝旧编辑保存。Agent失效工具需显式移除；AI失效动作以占位保持正文和旧结果身份，不自动选择其他动作或终止在途快照。合同见docs/technical/saved-item-lifecycle.md。
