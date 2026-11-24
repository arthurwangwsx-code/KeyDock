# 当前状态总账

更新：2026-11-25。用户已授权在保留P0/P1验收义务的同时推进P2–P4。**完整产品仍为PARTIAL**；当前源码、真实系统验收、已发布版本分别记录，不能用代码或CI绿测替代日用验收。

2026-11-25开发增量：alpha.6功能分支已加入直接窗口／应用动作、独立应用动作设置与事务存储，76项定向回归、46项Python及部分原生双语观察通过。首次编辑和显示提前短路已修补，合成应用真实隐藏→显示、退出只请求一次和正常结束得到确认。当前源全量／CI／发行门禁仍在进行，正式alpha.5未被替换。详见[本轮增量复查](implementation/desktop-controls-2026-11-25.md)。

后续完整目标已推进至已发布并安装的alpha.5：独立剪贴板面板、键盘搜索／预览／复制／受控插入、快捷键分类和视觉修补。完整本机检查、同源core CI、签名公证、正式安装和GitHub发行资产审计通过。见[本轮实查](implementation/clipboard-panel-2026-11-24.md)及[完整目标矩阵](product/quick-actions-completion.md)，不将此增量代替原P0–P4或关闭真实插入／物理热键／AI质量验收。

## 当前源码

canonical目录唯一；剪贴板分支从master `43aca85`创建，验收后的`7541c25`已受控fast-forward到master并标记`v0.1.0-alpha.5`。发行证据在从master创建的`chore/alpha5-release-evidence`补齐，不修改已发布字节。主Agent独占写入／集成／提交／设备，子Agent只读研究评审或提供/tmp原创提案。未新建worktree或修改AiBox／Ashot。

| 范围 | 状态 | 当前证据与限制 |
|---|---|---|
| 产品／架构／开源参考 | PASS（工程） | 原生模块化单体、13项固定revision参考；AiBox只读设计对照，新代码独立编写 |
| 构建与模块 | PASS（本机） | Swift6／macOS14目标，当前27.2 arm64原生构建；最低系统未真实验证 |
| 启动台／设置／工作区 | PARTIAL | 独立窗口、菜单栏入口、KeyDockUI、系统玻璃材料和中英；基本深浅色／焦点已观察，完整视觉／辅助功能矩阵未完成 |
| 搜索与快捷键 | PARTIAL | 动作分类、剪贴板专用绑定／别名、目录／generation／过期结果和注册事务测试；Preview录制与重启持久化已观察，物理全局快捷键、IME／全屏／多屏未完整验收 |
| 窗口切换与布局 | PARTIAL | 13项布局、窗口identity恢复、最大交集选屏、负坐标／断屏clamp纯测试、AX写后读回；真实AX授权／撤销／多屏矩阵待验收 |
| CLI与任务 | PARTIAL | executable+argv、有限输出／超时、真实进程组取消与回收、durable intent／result／unknown不重放；Terminal GUI继续尊重既有工具拒绝，未计真实通过 |
| 剪贴板 | PARTIAL | 独立两栏Panel、搜索／↑↓／预览／复制／受控插入、目标与取消／竞争围栏；中文浅色／英文深色及焦点修补已观察。记录默认关闭，未启用个人采集；真实插入、物理热键、多项合并仍待验收／建设 |
| AI服务与快捷动作 | PARTIAL | 自定义兼容API、Keychain事务、重定向保护、翻译／总结／命令建议／选区输出、loopback全链路；真实外部API按用户决定稍后配置 |
| AI质量 | NOT_RUN | 20条合成质量样本已准备；真实模型质量与人工评阅未执行 |
| 多步Agent | PARTIAL | 保存命令／MCP工具allowlist、冻结范围、schema／预算、逐次审批、暂停／新attempt与unknown回归；真实外部模型／工具组合未全面验收 |
| 工作流与App内计划 | PARTIAL | 编辑／输入输出绑定、完整动态argv审批、快照冻结、child drain、durable claim／指纹／revision／DST／睡眠合并／unknown检查；真实长期驻留仍待验收 |
| MCP与扩展 | PARTIAL | HTTP／stdio、两个显式协议版本、tools／resources／prompts及21项合成协议回归；第三方兼容未全面验收，ACP仅评估、无OS沙箱或扩展市场承诺 |
| OCR与文件文本 | PARTIAL | 真实合成Vision OCR、UTF-8／PDF文本层、预算／取消；区域截图入口已实现，Screen Recording由用户手动授予；未声称多模态原图发送 |
| 常用工具 | PARTIAL | Snippets、选定目录文件名搜索／Finder显示、算式／单位、URL模板、命令集合；核心回归和部分原生交互已通过，完整入口矩阵待验收 |
| 使用分析 | PARTIAL | 默认关闭、最小metadata、30天聚合、暂停／清除／导出与明确用户触发AI总结；只有工具内部分覆盖，无整机追踪 |
| 回执／历史／容量 | PARTIAL | 8管理任务／200历史／32草稿／32MiB逻辑预算、90天元数据维护、原子父子保护、显式清除；崩溃后不重放，长期／完整GUI矩阵待验收 |
| 性能 | PARTIAL | 早期2000命令Release排序／缓存链p95约21ms；新增无计划时不启动调度循环；热唤起150ms、真实RSS／耗电与长期驻留尚未证明 |

干净源`7541c25c1893c7e8237d87280525ec4c48702407`的完整本机检查与Release构建通过：400项Swift执行（core390＋Terminal生命周期9＋生产OCR1，两轮实际识别）、43项Python、524个中英UI key、文档及lifecycle helper。测试清单包含379个声明ID，参数化执行次数另计。测量`86372456-e6ae-4d16-bc81-5a3437507857`，14:35:16Z–14:41:52Z。

同源[core CI 45415628626](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45415628626)通过399项Swift、流水线检查及优化版Preview构建；云端系统OCR明确NOT_QUALIFIED。完整本机资格在macOS27.2 arm64／Xcode27.2，强制生产accurate／revision3／自动语言／纠正／支持CPU阶段配置，两轮识别通过。资格摘要`8e0efea04ebaed857f55893f23e30b067d9f7455dd2bba9931f1ccf87add5d73`同时封入App和manifest；不是第三方硬件认证或完整真实场景验收。

先前Terminal超时、并发HTTP等待与远端Vision失败均保留。现强制串行互补分区、独立服务准备与stdio启动预算，原退出／drain／普通调用时限不放宽。远端Vision仍为TextRecognition code9等诊断失败，未认定特定硬件根因。alpha.3已公证候选保持原字节、未安装／未公开；alpha.4增加了同源系统资格和精确CI门禁。详细失败、修复与回归见扩展能力证据。

详见[扩展能力证据](implementation/capability-expansion-2026-11-24.md)、[使用说明](product/expanded-tools-guide.md)、[技术合同](technical/capability-expansion.md)和[iSpec任务](../ispec/changes/keydock-foundation/30-tasks.md)。勾选仅表示对应实现／定向验证，不关闭本表更广的真实验收。

## 已发布与安装

公开仓库为[arthurwangwsx-code/KeyDock](https://github.com/arthurwangwsx-code/KeyDock)，默认分支master。用户已授权公开此项目源码、Release本地打包上传、流水线及本地安装替换。

- [alpha.5／build5](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.5)已公开并安装至`/Applications/KeyDock.app`，App源为上述`7541c25`。Developer ID／Hardened Runtime、App与DMG公证装订、Gatekeeper、只读DMG内部App一致性、公开后实际回下载均通过。运行中的alpha.4正常退出后原子替换，旧App及回退receipt保留；未force kill或改TCC。
- [GitHub发行资产审计45418462685](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45418462685)已通过，从精确发行tag下载并核验资产；不是云端OCR或真实剪贴板插入验收。
- 正式App已实际启动，「关于」显示`0.1.0-alpha.5 (5)`；正式隐私页仍显示需要辅助功能权限。Preview中文浅色／英文深色、查询／方向键／复制、快捷键录制／持久化已观察，语言／外观已恢复跟随系统；物理全局热键未计PASS。没有保存MCP来源、运行外部服务或配置真实API。
- [alpha.4／build4](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.4)为本次可回退旧版，源`fea2bee`；当时384 Swift／43 Python／506 key、发行及资产审计通过，见[扩展能力证据](implementation/capability-expansion-2026-11-24.md)。
- alpha.2／build2的历史源为`ace56efdf67faae0f8dd2df3f0871b8e61a7829f`，历史发行／安装验收见[alpha.2证据](implementation/native-actions-2026-11-24.md)；当前直接回退目标是alpha.4。alpha.3／build3仅保留本地候选；Preview的dirty源码构建不作为正式分发包。
- alpha.1／alpha.2／alpha.4原tag和资产字节保持不变。个人配置、bookmark、密钥、截图、剪贴板、正文和本机日志不进入公开资产。

## 历史证据与边界

此前第一阶段／视觉／任务／发行检查记录保留在[文档总览](README.md)。旧日志中的“尚未实现”仅描述当时alpha.2源码，不能套到本轮扩展源码；既有FAIL也不因后来通过被删除。

真实API仍按用户决定稍后配置，AX／屏幕权限不能代为绕过。物理快捷键、系统／多屏／IME／辅助功能、模型质量、完整视觉评审和长期性能尚未关闭，因此不报告“全部功能与验收已完成”。支持与隐私请求：arthur.wang.wsx@gmail.com。
