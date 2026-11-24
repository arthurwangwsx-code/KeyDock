# 窗口与应用控制增量复查

日期：2026-11-25（本地）；测量时间使用UTC。**完整产品仍为PARTIAL，alpha.6已正式安装并公开。** 本轮从`feature/desktop-control-actions`交付，不把下面的定向检查当作全部窗口／应用验收。

## 源码与工程边界

分支从master的`ef9e910`创建，只有canonical checkout、只有主Agent写入。首个功能提交为`59e3069b02d3e99de399402b45ff6864584ca543`，修补后冻结为`d61598af39baad9296af0dd8f399a267b43f4e96`，完整检查与只读评审后受控fast-forward到master，标记`v0.1.0-alpha.6`并推送获授权的KeyDock仓库。发行证据仅在后续chore分支补齐，不改tag或已发布字节。AiBox继续仅作设计参考，本轮未搬运其源码、数据或凭据。

新增独立应用动作设置、稳定窗口循环／最小化、直接快捷键dispatcher、精确effects、任务intent及独立动作档案。详细合同见[稳定窗口与应用动作](../technical/desktop-actions.md)。真实API仍按用户决定稍后配置；没有借用密钥或发起付费请求。

## 实现与定向验证

| 范围 | 当前结果 | 证据与限制 |
|---|---|---|
| 窗口顺序模型 | PASS | 16项合成场景覆盖raise后重排、关闭／新增、外部焦点、旧nonce、取消与128项容量；原生AX写入仍待授权及真实矩阵 |
| 应用动作档案 | PASS | schema／容量与13项文件事务回归，固定dirfd、交换／首次创建、外部编辑、补偿fsync、残留停写；故障注入不等于掉电验收 |
| 应用状态机与策略 | PASS（合成） | 单次请求、退出未结束、负回执后的状态变化、步骤间撤销、精确effects与拒绝模型借用；真实方法另列 |
| 新编辑器与双语 | PASS（已观察子集） | 中文浅色／英文深色、首次编辑、取消、新建无默认应用、空白校验；完整视觉／辅助功能矩阵仍未完成 |
| 全局快捷键 | PARTIAL | 新动作录制`Ctrl+Option+Shift+J`、别名`kst`并跨Preview替换保留；工具注入未触发全局动作，原因未定，不计物理热键PASS |
| 正常退出 | PASS（合成原生宿主） | 宿主拒绝退出时只观察到1次请求，KeyDock保留“已请求”；用户明确允许后再次触发，目标实例正常结束并确认 |
| 多窗口控制 | 待验收 | 实际AX循环／最小化、多屏、Spaces与权限变化矩阵仍未完成 |
| alpha.6发行 | PASS（工程） | 当前干净源全量检查、同源CI、公证／安装／公开回下载通过；具体摘要见下节，完整产品仍为PARTIAL |

定向测量`558095aa-e8ec-45f7-957a-91dc22136c31`通过76项执行，覆盖当前窗口模型、档案、应用状态机、显示步骤与宿主策略。另测量`ddc0a9de-17c4-4c46-b7c6-a7bf33bf974e`通过29项相关执行，包含旧界面分类用例修订。两者有重叠，不能相加当成独立测试总数。

## 全量资格与发行

冻结源`d61598a`的测量`19ec223d-b5ca-4dc3-a207-7c1e47104c49`在17:11:56Z–17:18:52Z通过完整check及Release构建：457项Swift执行（core447、Terminal9、生产OCR1；两轮实际识别）、46项Python、556个中英UI key；436个声明ID与参数化执行分别计数。macOS27.2 arm64／Xcode27.2资格摘要为`8e7f72f686b6e2c1878e4d9fb8fa5f2838955129caf7e49c1a77de2cd10ed5dc`，它是公开summary规范化摘要；本机外层资格文件另有文件摘要，不能混作同一值。

同源[core CI 45445721343](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45445721343)成功，云端OCR仍为NOT_QUALIFIED。App公证`27c71180-dac4-4b38-8e15-a468b96ea0d3`与DMG公证`c53f3e30-0344-449a-ac4f-125dab2f6070`均Accepted；装订、Gatekeeper和只读DMG内部App一致性通过。打包测量`942d7ed3-fe35-42af-92ad-819442ebd124`、安装测量`a0524f85-1f2f-4ed2-94df-a6716b8c3ba0`、发布及实际回下载测量`afa43624-65c7-45ac-9f87-3d3abc7457d7`均exit0。

[公开alpha.6](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.6)于17:27:34Z公开为prerelease。ZIP摘要`ab05b3b0e51b1a586f9f34623156d02992a8c18fb78072adf86a087e541a0147`，DMG摘要`9ca7e89c1181b46a54a4b94c03b12a826f09fa07b855f11a5db8e8a57e1586a0`，manifest文件摘要`c9428d4d79104c1bf019b2c7c85ab9e277cb464df2937e95209536d27831ba78`。[独立GitHub发行资产审计45448806865](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45448806865)成功，不代替本机OCR或物理交互。

正式`/Applications/KeyDock.app`已原子替换，bundle摘要`8920ead1edfc87bfc2875b0335cbdf31b9eecfaa78746adac89ee827e1ea948d`；原alpha.5及安装／回退receipt保留。原生「关于」实际显示`0.1.0-alpha.6 (6)`。没有读取正式剪贴板历史、添加权限或配置真实API。当前apply attempt已审计44份测量收据并核对实际文件摘要，42次exit0、2次早期失败均保留；整个apply仍运行，未将增量发行当作完整阶段完成。

## 原生观察、失败与修补

原生操作使用独立KeyDock Preview与`KeyDock Desktop Fixture`，三个窗口只有明确的合成文本。没有打开正式剪贴板历史、启用真实采集、读取用户终端历史或修改TCC。Preview数据仅用于本地验收，不进入发行资产。

1. 新建应用动作、录制快捷键、保存别名及替换Preview后的保留均已观察。应用动作进入Launcher目录，别名检索只返回预期目标。
2. 首次点击编辑时曾出现空名称及新建默认应用，属于实际UI失败。改为按`EditorInput`身份呈现sheet后，首次编辑正确载入已保存的名称／应用／行为，且英文深色复查一致。新建动作要求用户明确选应用，不再默认选目录首项。
3. 菜单选择与保存不能只凭点击次数判断。一次批量工具操作保存时仍保留旧行为，已通过重新读取字段、确认菜单关闭、保存后核对列表纠正；没有执行错误目标。后续验收必须核对实际值。
4. 设置返回Launcher曾过度依赖全局快捷键；新增普通「显示／View」菜单，提供Launcher、剪贴板及Workspace入口，原有状态栏菜单继续保留。
5. 新入口没有撤销旧桌面调用的问题在静态评审发现并修复。Launcher／Settings／Workspace／Clipboard及新的不兼容桌面意图会撤销旧lease；同实例窗口循环保留有界串行队列。内部dismiss不撤销当前新调用。

原生应用回执保留如下，不把后续成功抹去早期失败：

| 本地合成回执ID | 结果 | 说明 |
|---|---|---|
| `40F69F87-6EC7-45F8-B6CC-AE7807D115AC` | unknown | 检查／重新打开Preview相邻的首个调用；未认定已确认，也未自动重试 |
| `03C73287-D4AE-419B-BC0F-0B508F8B2F9F` | confirmed | 仅观察目标应用后，合成应用激活得到真实状态确认 |
| `150D826F-6C53-4919-9446-506A23FE62F0` | declined | 旧诊断只有统一拒绝，不能据此推断具体系统原因 |
| `F104B3A7-3400-4736-A898-A253A548DEA1` | noOp | 后续检查已隐藏；不以此逆推上一条回执的API返回原因 |
| `F3728430-5673-4CAF-9D6E-1C0DFB09A483` | systemRequest declined | 显示请求在观察窗口内未确认，保留失败 |
| `3D44881C-3D82-45CB-A1C3-ACA84EADEC36` | confirmed | 后续显示／激活调用确认，已实际查看合成窗口；不能替代单次隐藏→显示完整矩阵 |
| `E5EEE31E-23A8-4DD1-9A99-88EA46F8B7D4` | confirmed | 分步显示修补后的新一轮隐藏，实际目标状态确认 |
| `0F18AE70-2E13-4862-B609-67E9BC2108BC` | confirmed | 紧接上述隐藏后的首次显式显示请求确认，并实际查看窗口重新出现 |
| `637413AE-1AF8-4637-812A-EEF856A5E183` | quitRequested | 测试宿主拒绝退出且保持运行，界面计数从0变为1；KeyDock不误报目标已结束 |
| `FFE16B6A-E78D-42DF-89CF-D87652FB5DF8` | confirmed | 关闭测试宿主的拒绝开关后，第二次显式请求使原实例正常退出；原生应用清单中目标已不存在 |

随后修正明确的提前短路：`unhide()`返回false不能代替最终状态，也不应跳过同一显式“显示并激活”动作中已批准的`activate()`。两步骤之间检查lease及原PID／launchDate／安装路径，最后有界读回；没有重复派发同一步。观测到部分变化时，即使两个返回都未报告接受，也保留unknown。系统日志中启动期另有AppleEvents诊断，但没有建立与显示调用的因果关联；本轮未因此增加entitlement或改变系统授权。

静态评审、合成回归及上述隐藏→显示／正常退出子集已通过。测试开关实际由NSApplication返回terminateCancel；没有验证真实保存对话框或terminateLater，不把它描述成这些场景的完整证明。没有强退、关闭保存提示、重放或自动重试。两个退出请求分别来自两次明确的UI触发。

Preview语言、外观已恢复跟随系统；应用动作`Synthetic quit`、别名与测试绑定保留在隔离数据中，合成宿主已正常退出。受测对象为开发中dirty Preview；本机回执核验绑定实际Preview binary SHA及BuildInfo来源，不能替代正式分发资格或最低系统／第三方应用矩阵。

测量`06975a89-b245-415e-8608-5b3cb8390e41`仅核验上述四条新回执与实际Preview binary来源，原生UI操作和计数由CUA分别观察；不是自动化GUI全链资格。

## CI与构建记录

首个源`59e3069`的[CI 45434718459](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45434718459)失败：旧`InterfaceBehaviorTests`仍要求窗口分类只有13项。当前产品合同已增加3项稳定窗口动作；用例改为验证13项布局和明确的3项动作ID，保持拒绝临时窗口ID。修订后的定向及全量回归通过，新源CI成功；旧源失败记录继续保留。

Preview构建／本地替换均通过统一流水线，测量包括`c8b70d66`、`76410a34`、`0302f954`、`1fe06035`、`97c3b3ef`、`30e72c4a`。它们是开发中dirty Preview，不是正式分发资格。完整日志和精确收据保留在忽略的本机`.local/desktop`及iSpec receipts；没有把个人配置、路径、窗口引用或正文上传到GitHub。

上述完整工程门禁已经通过。原TCC／模型质量／多屏／最低系统／IME／辅助功能及长期性能义务继续保留，剪贴板多项合并依任务10.7继续建设。

## 宿主空间与调试恢复

验收期间出现原生工具超时和命令变慢。只读检查确认数据卷曾仅余154,536 KiB；Preview两秒进程抽样处于正常AppKit事件等待，单点physical footprint为63.2M，不能据此声称长期性能通过。恢复空间后原生检查继续完成；未对超时来源作唯一因果归因。

确认没有本工程活动编译后，仅移除本工程6个可重建Intermediates.noindex／ModuleCache.noindex目录，保留Products、源码WIP、发行包、安装备份、日志与收据。清理收据记录删除前3,741,556 KiB、删除后4,267,636 KiB，约回收0.5GiB；此前其他宿主变化不归功于该操作。

统一check／build增加2GiB可用空间预检，doctor报告实际值及准备状态；空间不足时记录检查失败并在编译前停止，不复用伪成功。46项Python流水线回归通过，包含容量边界、失败记账及拒绝启动构建。此门槛是工程余量要求，不能保证其他进程不会继续消耗空间。
