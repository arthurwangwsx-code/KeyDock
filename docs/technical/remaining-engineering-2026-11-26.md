# 原目标剩余工程与系统验收

2026-11-26，三位子Agent只读复核alpha.20源`aa0edfc`，主Agent统筹。以下是原P0–P4及用户快捷操作目标的实施细化，不是额外产品承诺；现有任务与完整验收义务保留。

| 范围 | 已有实现 | 下一工程切片与证明 |
|---|---|---|
| 10.1–10.2真实快捷操作 | 独立剪贴板、搜索／选择／有序合并／插入事务、应用与窗口命令／绑定 | 独立DesktopReview配置／bundle／profile／owned目录，限制一般上下文、凭据、匿名网络及调度恢复；窄准入绑定合成宿主，仍走原Host授权／paste事务。核对原目标恰好接收一次、目标变化拒绝、取消和重启不重放；TCC与实体键盘单列 |
| 10.3自定义完整性 | 别名、收藏、应用动作、集合及工具定义已有 | 收藏改候选配置事务并在Launcher反馈写入失败；动作菜单消费真实Reveal／Copy标题；命名应用动作删除统一引用检查与偏好清理。验证写前／写后故障、旧确认、重启、取消及磁盘／内存一致 |
| Agent预算规范 | 已有步数／工具数／时间／字节门禁，每请求默认输出上限 | 定义级每请求／运行总token额度，冻结并去重累计，下一请求前检查剩余额度。费用只按冻结费率及报告usage可测，缺报保持未知或暂停，不宣传账单硬上限。合成预算耗尽后零后续HTTP／工具 |
| 5.5／完整RunStore | 四类定义引用、run／attempt、CAS、新授权、新UUID及可选材料 | 复用InvocationStore／journal持久化无正文步骤sequence、状态与调用引用。A成功／B失败重启后仍可逐项核对且无自动重放；checkpoint新尝试另行设计重新授权与unknown核对，材料回填不能宣称续接 |
| 原图／附件 | 文本／PDF／本地OCR及单文本上下文槽 | 先支持明确选择的一张PNG／JPEG，默认text-only，显式模型图像能力后编码content parts；尺寸／字节、revision、移除／关闭／取消和缓存释放。合成图loopback验证，不支持能力时零HTTP，不进导出／普通日志 |
| 4.7增量用量 | 累计快照、部分／未知、费率快照与叶子计价 | 可选稳定eventID、有界去重及明确协议adapter，无身份仍拒绝delta；验证重复、乱序、冲突、溢出、累计混用与取消，旧历史可读且不重复计价 |

当前源码的具体接缝为`toggleFavorite`先改内存再保存；Launcher动作菜单按kind显示Open／Run／Switch；`application-action`未统一进入删除引用与失效偏好清理。它们是工程缺口，不能只靠更多实机验收解决。AgentDefinition没有运行总token／费用字段；AIMessage仍是字符串，OCR不代表已支持原图发送；Workflow checkpoint仍在内存。

DesktopReview必须保留Preview SafeSmoke及`allowContextCapture=false`，通过宿主注入的窄目标能力贯穿捕获前、Host插入入口及每次异步后复查。只调用位置元数据的`capturePasteTarget`，不调用会读取选区正文的`captureTarget`。单独bundle不自动隔离数据目录；新模式需要owned根与marker持续身份围栏、inert ClipboardCaptureSource、拒绝凭据／一般读取端口、空应用索引、受限菜单和运行策略。它不是OS沙箱，也不自动授权TCC；Review身份通过不代替正式App身份资格。

已实现但未充分证明的项目另列：真实目标消费／权限撤销／多屏实际读回，完整中英深浅／IME／VoiceOver／焦点与尺寸矩阵，真实屏幕首帧和热唤起trace、8小时含睡眠驻留，以及配置真实API后的模型质量。查询基准不等于150ms实际呈现，CUA注入不等于实体键盘。

ACP当前合同是可选adapter评估：已有评估但无adapter；不能称为已支持，也不能因竞品参考自动升级成本轮MUST。图片／文件剪贴板和PTY等后续演进保持既有范围。只读参考AiBox设计，未把私有源码、截图、会话或凭据迁入公开仓。
