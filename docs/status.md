# 当前状态总账

更新：2026-11-23。当前范围为第一阶段 P0+P1 实现，目标保持“首个可日用 macOS 内测版”。整体状态 **PARTIAL**：已有可构建、可运行预览，完整日用验收尚未完成。最新增量见[玻璃界面与双语复查](implementation/interface-refinement-2026-11-23.md)。

| 范围 | 状态 | 当前证据与限制 |
|---|---|---|
| 产品/竞品/参考规划 | PASS | 三路调研与评审、13项固定revision参考，历史规划回执保留 |
| 原生工程与模块 | PASS | 根SwiftPM多target、原生App薄壳、XcodeGen、macOS14目标、Swift6编译；只验证当前27.2/arm64主机 |
| 命令/搜索核心 | PARTIAL | 排序/别名/收藏/最近使用、异步generation测试通过；执行策略已贯通宿主动作与只读工具，宿主授权消费动作声明，真实边界仍待验收 |
| 视觉与窗口职责 | PARTIAL | 新版三窗口、原生Liquid Glass、双语切换、基本深浅色和AI焦点已实际观察并修正；辅助功能／IME／多屏完整矩阵及用户视觉评审仍待完成 |
| 原生界面与CLI | PARTIAL | CUA已验证搜索启动计算器、保存命令、搜索执行、输出、取消及输出进入AI；全局物理快捷键、IME/多屏/全屏仍待验收 |
| 窗口与选区 | PARTIAL | AX异步快照/身份/失效/替换/精确窗口恢复代码已实现；真实辅助功能授权后验收尚未执行 |
| 剪贴板 | PARTIAL | SQLite与敏感类型过滤、稳定快照、暂停/排除/过期/固定/清除及合成测试；actor全文搜索、单项预览/复制、独立行按钮已用合成数据实查；新增容量预检/事务回滚与生产采集惰性读取门槛回归；未启用个人采集 |
| AI API/动作/Agent基础 | PARTIAL | Provider和真实URLSession loopback通过；新增Store全链路覆盖任务／用量／取消／建议不执行／过期隔离／只读工具两轮／脱敏；输入/输出预算、空响应与取消、过期复制围栏通过；结果与任务详情展示待报告/已报告/部分/未知用量，缺报Agent轮次保留unknown；外部API按用户决定稍后配置 |
| AI质量 | PARTIAL | 20条合成质量样本已准备，全部NOT_RUN；未进行真实模型调用与人工质量验收 |
| 最小任务与回执 | PARTIAL | CLI/AI网络前intent、终态元数据与退出围栏通过；三个AI入口的专用子进程SIGKILL+Store恢复通过且不重放；当前新版原生App带sleep退出已验证；Terminal交接有界/unknown/迟到隔离的合成测试通过，完整GUI崩溃和真实Terminal仍待验收 |
| 性能 | PARTIAL | 2000条合成命令100次采样，Release排序p95 20.47ms、生产缓存查询链路p95 20.85ms；Panel热唤起150ms和长期耗电尚未证明 |
| 公开托管/发行 | PASS（alpha工程） | public／master与v0.1.0-alpha.1已公开；Developer ID、App/DMG公证、Gatekeeper、本地安装、GitHub资产复核及cb74c41完整原生CI通过；完整日用仍PARTIAL |

详见 [第一阶段进度](implementation/phase-one-progress.md)、[验收方案](technical/validation.md) 和 [iSpec任务](../ispec/changes/keydock-foundation/30-tasks.md)。勾选任务表示对应实现/定向验证完成，不替代本表更广范围的真实验收。

canonical checkout 仍唯一，开发分支 feature/phase-one 从master创建，主Agent串行写入，子Agent只提供/tmp独立补丁和只读评审；未创建worktree、未改旧AiBox/Ashot工程。支持/隐私联系 arthur.wang.wsx@gmail.com。

当前248项Swift测试与32项Python流水线测试通过；271条UI key中英文静态覆盖通过。查询合同进入生产Launcher与QueryCoordinator，迟到请求不能取消新请求，Return不能执行旧批次。最新实际检查与边界记录见[界面与任务复查](implementation/native-ui-hardening-2026-11-23.md)，早前画面和查询记录保留。终端UI由工具明确禁止访问，旧适配路径未产生合成marker；新的有界回调适配器已编译并通过合成验证，真实交接不计通过。CUA注入alt+space未触发可观察切换，物理快捷键仍未验收。

此前GUI复验曾因Mac锁屏未执行；应用目录更新、快捷键事务、迟到启动回调与用量状态的最新合成证据见[本轮复查](implementation/application-shortcuts-2026-11-23.md)。本轮已实现任务/草稿总预算、90天元数据维护与两类独立清除，合成验证通过；原生清除交互与长期驻留仍待验收，32MiB为逻辑文本预算而非进程RSS承诺。

本轮细化玻璃／控件／正文分层与高对比度、共享按钮、快捷键精确深链接和可返回AI草稿；语言／外观／命令候选保存失败回滚，应用提示运行时双语解析，剪贴板写入失败保持本次暂停。代码与合成验证通过；当时Mac锁屏；本轮已解锁，新增实机证据见发行工程实查。

本轮新增调试／安装／发行流水线与合成、真实签名App验证，详见[发行工程实查](implementation/release-engineering-2026-11-23.md)。源码已推送，首个签名公证alpha已公开并安装。最终原生复验时工具确认Mac已锁屏，最新视觉修复和正式包首次启动保持待验收。

远端原生CI在44ace89曾出现WorkbenchFeatureTests失败，旧摘要未包含具体用例；加入完整诊断后，cb74c41的同一组248项Swift／32项Python检查及ReleasePreview构建通过。未放宽断言或增加超时，先前失败根因仍未定位，不能宣称稳定性问题已修复。[远端通过记录](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45202054398)。
