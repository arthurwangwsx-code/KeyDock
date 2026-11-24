# 当前状态总账

更新：2026-11-24。用户已授权在保留P0/P1验收义务的同时推进P2–P4。**完整产品仍为PARTIAL**；当前源码、真实系统验收、已发布版本分别记录，不能用代码或CI绿测替代日用验收。

## 当前源码

canonical目录唯一；当前分支`feature/desktop-capability-expansion`从master `a147e3c`创建。主Agent独占写入／集成／提交／设备，子Agent只读研究评审或提供/tmp原创提案。未新建worktree或修改AiBox／Ashot。

| 范围 | 状态 | 当前证据与限制 |
|---|---|---|
| 产品／架构／开源参考 | PASS（工程） | 原生模块化单体、13项固定revision参考；AiBox只读设计对照，新代码独立编写 |
| 构建与模块 | PASS（本机） | Swift6／macOS14目标，当前27.2 arm64原生构建；最低系统未真实验证 |
| 启动台／设置／工作区 | PARTIAL | 独立窗口、菜单栏入口、KeyDockUI、系统玻璃材料和中英；基本深浅色／焦点已观察，完整视觉／辅助功能矩阵未完成 |
| 搜索与快捷键 | PARTIAL | 目录／generation／过期结果和注册事务测试；物理全局快捷键、IME／全屏／多屏未完整验收 |
| 窗口切换与布局 | PARTIAL | 13项布局、窗口identity恢复、最大交集选屏、负坐标／断屏clamp纯测试、AX写后读回；真实AX授权／撤销／多屏矩阵待验收 |
| CLI与任务 | PARTIAL | executable+argv、有限输出／超时、真实进程组取消与回收、durable intent／result／unknown不重放；Terminal GUI继续尊重既有工具拒绝，未计真实通过 |
| 剪贴板 | PARTIAL | 默认关闭、敏感类型先过滤、惰性正文、暂停／排除／TTL／容量／固定／清除和合成UI验证；未启用个人采集 |
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

本轮最终统一检查通过382项Swift（主体373＋独立Terminal生命周期9）、34项Python、503条UI key中英覆盖及lifecycle helper编译。此前两次混合套件检查的两秒退出断言FAIL保留；第二次实际shutdown为2.087s，3.688s是整个用例耗时。并发MainActor合成夹具含同步poll／usleep，现将Terminal套件作为互补且强制的独立阶段，时限不变、空匹配拒绝；提交时捕获绝对deadline并独立计时。见`expansion-unified-check-v3`，不把繁忙系统视为硬实时系统。

干净源首次release随后因超长AI输出的五秒drain超时停止，未生成发行资产。显式`--no-parallel`的19项集成诊断通过，日志确认套件不再重叠；两个Swift阶段均已追加显式串行，原预算／等待／断言不变。最终新版发行检查尚在进行，失败日志继续保留。

显式串行check-v4已通过全382／34／503；首轮远端CI另有Vision unknownError。OCR现按Apple API为各阶段选择其声明支持的CPU，本机六项上下文测试（含真实合成图识别）通过；新版完整本机发行／远端复验结果待记录，不把unknownError擅自定性为VM硬件缺失。

详见[扩展能力证据](implementation/capability-expansion-2026-11-24.md)、[使用说明](product/expanded-tools-guide.md)、[技术合同](technical/capability-expansion.md)和[iSpec任务](../ispec/changes/keydock-foundation/30-tasks.md)。勾选仅表示对应实现／定向验证，不关闭本表更广的真实验收。

## 已发布与安装

公开仓库为[arthurwangwsx-code/KeyDock](https://github.com/arthurwangwsx-code/KeyDock)，默认分支master。用户已授权公开此项目源码、Release本地打包上传、流水线及本地安装替换。

- 已发布并安装alpha.2／build2，App源`ace56efdf67faae0f8dd2df3f0871b8e61a7829f`；当时251项Swift／32项Python／273条文案、原生CI、Developer ID／App与DMG公证、Gatekeeper、运行中升级、回退与公开资产审计通过。见[alpha.2证据](implementation/native-actions-2026-11-24.md)。
- alpha.3／build3为当前候选，扩展功能已在独立Preview观察；正式版本尚待最终干净源构建、签名公证、CI、安装与公开回下载核验。Preview的dirty源码构建不是正式分发包。
- alpha.1／alpha.2原tag和资产字节保持不变。个人配置、bookmark、密钥、截图、剪贴板、正文和本机日志不进入公开资产。

## 历史证据与边界

此前第一阶段／视觉／任务／发行检查记录保留在[文档总览](README.md)。旧日志中的“尚未实现”仅描述当时alpha.2源码，不能套到本轮扩展源码；既有FAIL也不因后来通过被删除。

真实API仍按用户决定稍后配置，AX／屏幕权限不能代为绕过。物理快捷键、系统／多屏／IME／辅助功能、模型质量、完整视觉评审和长期性能尚未关闭，因此不报告“全部功能与验收已完成”。支持与隐私请求：arthur.wang.wsx@gmail.com。
