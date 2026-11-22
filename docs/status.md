# 当前状态总账

更新：2026-11-22。当前范围为第一阶段 P0+P1 实现，目标保持“首个可日用 macOS 内测版”。整体状态 **PARTIAL**：已有可构建、可运行预览，完整日用验收尚未完成。

| 范围 | 状态 | 当前证据与限制 |
|---|---|---|
| 产品/竞品/参考规划 | PASS | 三路调研与评审、13项固定revision参考，历史规划回执保留 |
| 原生工程与模块 | PASS | 根SwiftPM多target、原生App薄壳、XcodeGen、macOS14目标、Swift6编译；只验证当前27.2/arm64主机 |
| 命令/搜索核心 | PARTIAL | 排序/别名/收藏/最近使用、异步generation测试通过；执行策略已贯通宿主动作与只读工具，真实边界仍待验收 |
| 视觉与窗口职责 | PARTIAL | 新版三窗口、原生Liquid Glass、双语切换、基本深浅色和AI焦点已实际观察并修正；辅助功能／IME／多屏完整矩阵及用户视觉评审仍待完成 |
| 原生界面与CLI | PARTIAL | CUA已验证搜索启动计算器、保存命令、搜索执行、输出、取消及输出进入AI；全局物理快捷键、IME/多屏/全屏仍待验收 |
| 窗口与选区 | PARTIAL | AX异步快照/身份/失效/替换/精确窗口恢复代码已实现；真实辅助功能授权后验收尚未执行 |
| 剪贴板 | PARTIAL | SQLite与敏感类型过滤、稳定快照、暂停/排除/过期/容量/固定/清除实现及合成测试；未启用真实个人剪贴板采集 |
| AI API/动作/Agent基础 | PARTIAL | Provider和真实URLSession loopback通过；新增Store全链路覆盖任务／用量／取消／建议不执行／过期隔离／只读工具两轮／脱敏；外部API按用户决定稍后配置 |
| AI质量 | PARTIAL | 20条合成质量样本已准备，全部NOT_RUN；未进行真实模型调用与人工质量验收 |
| 最小任务与回执 | PARTIAL | UI状态/输出/取消、进程组、0600原子回执/恢复围栏已实现并测试；正常退出/实际崩溃与Terminal handoff尚待全面验收 |
| 性能 | PARTIAL | 2000条合成命令100次采样Release排序p95 21.65ms；Panel热唤起150ms和长期耗电尚未证明 |
| 公开托管/发行 | PARTIAL | 未创建GitHub远端、未推送、未公证；当前仅本地ad-hoc Debug构建 |

详见 [第一阶段进度](implementation/phase-one-progress.md)、[验收方案](technical/validation.md) 和 [iSpec任务](../ispec/changes/keydock-foundation/30-tasks.md)。勾选任务表示对应实现/定向验证完成，不替代本表更广范围的真实验收。

canonical checkout 仍唯一，开发分支 feature/phase-one 从master创建，主Agent串行写入，子Agent只提供/tmp独立补丁和只读评审；未创建worktree、未改旧AiBox/Ashot工程。支持/隐私联系 arthur.wang.wsx@gmail.com。

当前77项测试通过；201条UI key中英文静态覆盖通过。查询合同进入生产Launcher与QueryCoordinator，迟到请求不能取消新请求，Return不能执行旧批次。新版实际检查记录见[原生界面复查](implementation/native-ui-review-2026-11-22.md)。终端UI由工具明确禁止访问，旧适配路径未产生合成marker；显式Terminal适配已修并编译，真实交接不计通过。
