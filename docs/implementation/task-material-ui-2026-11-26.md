# 任务内容原生审阅与显式输入复用

2026-11-26，继续`feature/task-material-retention`，主Agent单写；基线`a5deaca8a63e117f0054eef21d96c352d0805794`。基线[原生CI 45707552951](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45707552951)已通过，但这不代表本轮随后新增的UI源码取得同源CI资格。正式安装和公开Release仍为alpha.19，alpha.20尚未发行。

## 实现与状态

| 范围 | 状态 | 事实与限制 |
|---|---|---|
| 默认关闭／准确捕获 | PASS（定向） | typed AI、CLI、Agent、Workflow沿用同一生产入口；准确输入与后来编辑稿分离，CLI不把argv/env编码为输入。无关单项删除／TTL仅撤销内容票据，不撤销运行中的捕获许可 |
| App维护与历史清理 | PASS（定向） | 独立启动恢复删除意图，owner批量读取不确定时保留正文；历史先清对应birth正文再删父记录，失败保留metadata；纯内存逐出不删除磁盘内容 |
| 预算与收口 | PASS（定向） | read在await前预留解码上界，关闭时不提前释放未完成worker预算；save在创建Task前同步预留并单次接纳，实际完成才释放。shutdown等待读写／删除／维护收口后释放flock |
| 审阅／查看／删除 | PASS（实现及原生子集） | 独立稳定sheet、逐项冻结／默认均未勾选、Agent工具返回明确说明、私有正文不进入导出；删除先显式勾选。原生最终删除点击未执行，模型真实文件删除与失败路径已检查 |
| 输入复用 | PASS（定向及原生子集） | 绑定呈现／review／inputRevision／request／material version／文件身份／generation，超限编辑和Unicode ABA也失效。仅填原输入，已有文本需预览后明确替换，无结果兜底、无自动提交 |
| 独立内容库 | PASS（实现／定向）／PARTIAL（原生） | `Saved content`侧栏及隐私设置入口，header-only列表与任务200条内存记录独立；内存逐出后仍能查看及准备新尝试。标题固定预算、最多200行。新列表原生布局尚待复查 |
| 视觉／物理／发行 | PARTIAL | 已观察中文浅色和英文深色的短正文子集；长正文、失败态、完整明暗／辅助功能／IME／全屏多屏、物理热键仍开放；未将退出0或模型绿测当作完整产品验收 |

关闭保留先撤销运行时许可并释放临时审阅，配置失败仍保持本会话关闭，并提供再次保存关闭状态的入口；已存文件仍可读取。文件在7天后过期并拒绝读取，到期清理发生在下次App维护，App关闭时没有后台删除保证；不是应用级加密或SSD安全擦除。

## 定向与原生证据

同一iSpec apply attempt `9881b6d8-e08e-4176-b6a2-97706ee67811`，共享存储8GiB租约内串行运行。

- `task-material-library-v1`：140项定向通过（Workbench123＋RunStore17），receipt SHA256 `1978306342a49855548a5fe633849d2e9ccb433df67d64f36f5f4d0cf7f56965`。含真实begin等待撤权、2000个metadata key的少量正文清除、保存后最后owner查询期间清除不复活、读取／保存真实worker预算、partial delete父记录保留、无关捕获保留、内存逐出后独立读取，以及新尝试的空值／NFD／非空替换／版本变化／超限ABA／迟到读取与结果不兜底。
- 首轮输入复用检查`task-material-input-flow-v1`保留FAIL：偏好更改推进原有配置范围审阅代次，旧review不能直接复用；测试先重新审阅后通过，未放宽执行门禁。最终更完整检查另行记录，不将上述次数套到新增标题本地化后的精确源。
- 优化隔离Preview `task-material-ui-preview-v1` exit0，86.999秒，receipt SHA256 `623b5a4de6790cabd0073439c4770961de6ca4d989cab9544e3739356ac0560e`；实际观察App摘要`a5821085839769fec1b1cfd9f5d63e6f98c9fb31db1d740a093e5e48016aa9a3`，基线a5deaca／dirty。它早于后续残留提示、到期说明、导出偏好与独立内容库修补，不能作为新精确源的发行资格。
- `task-material-native-review-v1/v2`均正常退出0；生命周期本身不证明UI通过。Cua实际观察中文浅色手动保存两字段、保留原始空白及NFD、只回填不执行、非空输入预览后显式替换、点击开始后才产生第二次纯变换任务；英文深色只读页及英语到期日期、重启仅恢复两份metadata，再点击后查看正文。默认均未勾选；删除按钮仅在勾选后可用，未点击最终删除。
- native结构复核`task-material-native-proof-v1` exit0，receipt SHA256 `48534763e1f7cf9fd9c8431d58734224750a9447bb348ac90e279bdbb45f9b61`。owned样例只有一份正文、两个typed成功attempt、原birth关联保持，重启后没有新attempt／CLI或工具回执，control idle。脚本只核对合成数据后置条件，不声称可替代截图／交互评审；不输出正文。

原生证据和进程记录在`.local/desktop/KeyDock-Review-ab5477f8-523b-4c92-97cc-567fc97ef688`与`.local/desktop/task-material-native-*.log/json`，均为本轮合成内容，不提交到开源资产。Cua在第一次退出后的AX观察重新启动默认Preview；已立即正常退出，未把该域内容用于验收。第二次退出只按owned child receipt确认，不再做退出后AX请求。Terminal和SecurityAgent既有工具拒绝始终遵守。

模拟⌥Space在有／无sheet时未形成可确认的快捷键触发证据，保留NOT_QUALIFIED，不能把“树未变化”写成全局热键互斥通过。App入口已加逻辑owner保护，但物理触发仍须独立验证。

## 待完成

独立内容库原生布局、长正文与保存失败／取消／清除的完整原生矩阵，以及干净源完整本机／指定同源CI／Developer ID与新候选协议App+DMG公证／发布／安装回退继续推进。完整RunStore、P0–P4、真实API与真实系统验收义务不由本轮子集关闭。
