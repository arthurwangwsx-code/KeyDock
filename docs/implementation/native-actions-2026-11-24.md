# 解锁后原生交互与快捷键复查

日期：2026-11-24。整体仍为 **PARTIAL**。本轮只推进第一阶段与发行修复，不将后续路线缩减为已完成。

## 实际观察与修复

在已安装alpha.1上复查独立启动台／设置／工作区、英文／中文与系统／深色外观、现有提示动态翻译、新建空草稿焦点及草稿恢复。工作区顶部裁切本次未复现；第一次AI导航后的CUA读取超时，后续截图与AX读取正常。进程采样主线程处于AppKit事件循环，不能据此声称产品死锁已定位或修复。

实际发现⌘Return没有运行草稿、设置工具栏出现空控件、命令页新增图标不可见。修复如下：

- AppKit原生File菜单提供运行／停止，按当前keyWindow解析草稿或选中任务；按钮共用运行门槛。空、外来、在途和退出中的草稿不接受运行，设置窗口不触发隐藏草稿。
- 命令／AI动作分类使用原生NSToolbarItem图标、提示和selector，保留已有未保存编辑；其他设置页隐藏无用工具栏。
- 工作区首次默认显示任务时选择已有恢复任务，再次显示保留原页面和草稿。

修复后的独立Preview实际完成：

1. 点击可见新增按钮，保存合成printf命令，运行后退出0并展示预期输出。
2. 将输出送入AI草稿，用⌘Return向本地合成服务发出真实URLSession流式请求，再用⌘.取消；保留部分输出与未知用量。
3. 只读Agent执行两轮请求和一个真实host current_time工具，完成后展示已报告输入30／输出10，费用未知。
4. 正常退出Preview，确认无该路径进程；原子恢复测试前的Preview配置，移除本次合成命令和localhost模型设置。正式应用配置未写入模型设置，未读取个人剪贴板或凭据。

服务当时记录POST3／Agent2／tool1／活动慢连接0／已关闭慢连接1／Authorization0。临时验证脚本首轮错误地把活动连接数当作累计数而失败；更正后重读时服务已停止，第二轮连接拒绝也保留为FAIL。此处原生UI成功来自实际观察与当时捕获的计数，不将两次失败receipt改写为E2E通过。

## 定向与完整检查

- 3项新增回归：共享运行门槛、未保存编辑保留、恢复任务与后续导航；定向40项测试通过。
- 全量251项Swift通过（Command15／Execution33／MacAdapters54／AI与Agent23／Workbench126）；32项Python流水线测试、273条UI key双语覆盖、文档和生命周期helper编译通过。
- 全量测量 `8c9b55b3-cec6-4311-9575-cbdb2f651547`，本地日志 `.local/nov24-full-check.log`；Preview最终构建／安装测量 `43cb8218-ebc3-4af6-bd7d-69967280f44a`。
- 独立只读评审未发现阻断；原生多窗口不同草稿／sheet打开时的路由仍需补实查，不把纯模型测试等同于AppKit键盘矩阵。

## CI失败定位

[旧原生CI 45205239086](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45205239086)的完整诊断已下载核验：唯一失败是用量展示测试 `failedSecondAgentTurnShowsOnlyItsKnownReportedPortion` 在fixture.drain的5秒预算内未收口，后续用量断言尚未执行。faaa9d6较前次通过cb74c41仅改文档。

该展示测试借用约1MiB的跨轮输出压力路由，受并行夹具和MainActor调度影响；具体慢子阶段无法从旧日志还原。同次CI的专用跨轮总预算测试通过。现用小型首轮工具调用／第二轮HTTP503故障路由检验展示语义，保留所有用量断言并增加请求计数；大响应预算测试和所有超时不变。新增超时诊断仅输出状态／字节数／计数，不输出正文。新提交CI需单独实跑，不能仅由本地通过认定远端问题已解决。

## 剩余边界

物理⌥Space、IME、多屏／全屏、VoiceOver／降低透明度等系统矩阵、用户视觉评审、AX授权／撤销与选区替换、真实Terminal仍未完成。物理按键和由用户手动授权的询问已发出，等待答复；不绕过系统权限。外部兼容API按用户决定稍后配置，模型质量仍NOT_RUN。

## alpha.2交付结果

源提交 `ace56efdf67faae0f8dd2df3f0871b8e61a7829f`，版本 `0.1.0-alpha.2`／build2。经本地全量检查、独立评审与[远端完整原生CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45327538178)通过后，受控fast-forward到master并建立精确tag；[同源master原生CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45328234945)随后也通过。无worktree或第二checkout，alpha.1的标签和字节保持不变。

- 正式Release构建／Developer ID／Hardened Runtime通过，编译测量 `e6c4d9ab-4686-4fc2-86ff-66d4255b5fbe`。
- App公证 `9c5e14f0-6de5-48db-9202-5e10bd3f97e2`、DMG公证 `3709fc03-9620-460e-bf44-947c715d788c` 均Accepted，装订、Gatekeeper和本地资产验证通过；打包测量 `2931fc59-bcd9-43ed-8b9b-613eb3afc7c4`。
- 正式alpha.1正在运行时，经脚本正常退出、原子替换成alpha.2。安装测量 `700e2d3f-5f30-41df-a178-c7fe7995bc09`；旧版原包、资源摘要与回退回执保留在本机，未执行降级回退，也未更改TCC。
- CUA在已安装alpha.2上确认完整AI工作区、原生⌘Return的未配置提示、新增按钮打开命令编辑器，以及设置窗口中运行／停止菜单禁用。取消测试编辑器后恢复空白草稿，未发出外部请求。进入工作区时又有一次CUA超时，随后重读成功，保留为工具／交互稳定性待观察项。
- [公开alpha.2](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.2)含ZIP、DMG、manifest和摘要四项资产；draft上传、两次回下载复核再公开通过，发布测量 `8f7c782b-1c5c-4d61-9009-967d136875cd`。[GitHub公开资产审计](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45328281923)通过。

ZIP SHA-256：`2df61f0bfe612219b7b0ec27f9b2af5ea22aff407f1b3f10b6afea5b84fff2af`。DMG SHA-256：`ac0fd294bf4334b6bb5fb9ef762e7f82e5c5fc2572290837d50a0cc6dc134c35`。

安装后额外核验脚本首轮误将包含executable／binary hash／architecture的完整检查结果与精简安装回执做全字典比较，产生误报；检查差异后确认共有字段及bundle摘要无变化，失败测量 `6bd000d7-222f-4e6d-8689-3e7068c3d874` 保留。更正为逐项验证全部回执字段并单独验证架构，不豁免任何资源摘要或签名检查。复跑测量 `23d9c8c2-b23d-4507-b7f2-6a8bcda8be94` 通过，确认启动中的唯一生产进程位于canonical App、当前alpha.2及保留alpha.1均与安装回执资源摘要一致。
