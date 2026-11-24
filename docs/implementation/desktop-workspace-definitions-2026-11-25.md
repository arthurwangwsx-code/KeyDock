# 桌面工作区定义管理复查

2026-11-25。主Agent独占canonical目录、分支、代码、构建和设备；子Agent只读审查。继续`fix/ui-semantics-and-text-sync`，正式alpha.7及alpha.8 OCR未放行不变。**本轮是定义管理增量，完整窗口组合执行尚未实现**；任务20.2／20.3／20.4不据此全部勾选。

## 实现

- CommandCore提供独立schema1档案、最多32个工作区／1MiB、每组1–8个有序目标、revision和严格策略；不保存PID／AX／窗口标题。路径仅词法校验，布局排除restore及相对换屏。
- MacAdapters抽出internal PrivateArchiveStore，旧ApplicationActionStore包装与磁盘格式保持；两个档案独立前缀隔离。原事务算法、dirfd身份、交换、fsync、补偿和未知数据保护共用。审查补齐创建候选前的字节预算检查。
- 新设置页和会话持有的编辑器支持应用选择、布局／屏幕／缺失应用策略、添加、移除及重排；expectedRevision拒绝过期覆盖／复活，真实更改才递增。审查发现no-op绕过磁盘校验后，增加无写入validateCurrent，替换／删除／目录漂移均拒绝并保留草稿。
- 仅贡献管理入口，窗口管理分类可绑定；执行profile不进入catalog，注册计划过滤未支持profile，设置拒绝新执行绑定。管理快捷键经原授权入口直接打开设置。保存定义不执行应用／窗口动作；跨档案的执行快捷键生命周期和完整runtime仍待任务20。

## 测量与失败

| 检查 | 测量 | 结果 |
|---|---|---|
| 旧store基础回归 | `33c226d6-e53e-4a08-8914-381ccd7528c1` | PASS，5项／1 suite；仅基础范围，不能代替后续事务回归 |
| 完整档案定向 | `29d277c3-1315-49a2-9a16-6a007c465a2e` | PASS，30项／6 suites（23＋7）；原store／事务／模型与新预算／定义／namespace故障 |
| 编辑v1 | `a286b6e7-edb6-42a6-bdc6-61132b465c03` | FAIL，测试错误访问private applicationItems；改经已存在的目录发布callback，不放宽生产封装 |
| 编辑v2 | `257c73ab-a587-4c85-9768-bc8230602e81` | FAIL，窗口分类旧总数16未包含新管理入口，仍保留13布局＋3窗口动作并另核对管理项；另一个带推断构造器的宏断言未给出有效Bool观察，改为显式HotkeyBinding并先取真实返回值再断言 |
| 编辑与事务v3 | `dd8e8797-68c4-4c48-b7ba-2f6518711170` | PASS，48项／6 suites（34＋14），23:10:39Z–23:11:17Z；含外部替换／删除／目录漂移、旧编辑、失效引用、版本／no-op和模态围栏 |
| Preview构建／替换 | `1ced48b5-af3f-4497-aaf7-af46332cf39e` | PASS，23:12:55Z–23:13:44Z；正常退出、原子替换和回退receipt保留 |

测试使用合成档案、应用目录发布callback和注入故障，不读取个人剪贴板、凭据或窗口；不启动外部应用。旧文件精确补偿、原无文件状态、未知残留／schema、超预算后仍可写、两个namespace互不污染以及基础配置重写均有回归。

曾读到磁盘仅约0.77GiB；第一次只读盘点后系统空间恢复到约2.22GiB，随后约2.9GiB，当时未删除缓存，Preview按原2GiB预检通过。完整检查前空间再次降至门槛以下；只在确认canonical路径、Git忽略和lsof无占用后清理本项目四个可重建目录：旧build/DerivedData、release／preview的DerivedData、旧SwiftPM架构缓存。保留当前.build/out、发布包／xcarchive、已安装App、日志与receipt。df实测可用约1.50→2.53GiB（增加约1.03GiB），没有清理其他项目或放宽预检。记录在本机`.local/desktop/desktop-workspace-cache-result.json`，完整core结果另录。

## 原生范围

隔离Preview中文浅色：Launcher搜索管理入口打开独立设置页；创建两个系统应用引用（Calculator／Activity Monitor）、分别右／左半屏，重排、保存并重新打开后顺序与布局保留。54个汉字（162 UTF8字节）的名称被拒绝，草稿与两项目标保留；修正后保存版本2。移除确认取消保留定义。

英文深色列表与620×590编辑器截图已检查，两张目标卡片、原布局与策略、滚动区及固定保存／取消均可用；无变化保存仍为版本2，修改名称后Esc取消不写入。语言／外观最后恢复Follow System。一次长菜单元素过期后重新读取并选择成功，不记作首次点击成功。

原生没有执行布局、启动这些目标、注册物理执行热键、提交永久删除、授予权限或请求API。真正的全目标冻结、焦点交接、父子回执／unknown、AX／多屏／物理热键和完整视觉仍未完成；不能用本轮编辑与模型通过代替它们。

## 完整核心范围

干净源`d1af256f80647526992023bbfb51f7dbe66d228f`完整cloud-core测量`cc4505ff-25fe-4be6-b50a-31daf41c91cd`通过，23:23:31Z–23:24:40Z：545 Swift／46 Python／660 key。摘要`.local/pipeline/20261124T232331312645Z/check-summary.json`清单525个声明ID（core515／Terminal9／OCR1），inventory SHA256为`128c232c0da3419109cd7061d172900b9f53fc010b8534d5a9117db7741dd29d`。此范围系统OCR为NOT_QUALIFIED，非完整发行资格。[同源CI45509658224](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45509658224)PASS，job138853780765的源码／流水线检查、Release优化Preview、归档与上传均通过；系统OCR仍NOT_QUALIFIED，诊断job未运行。
