# 玻璃界面、导航与双语复查

2026-11-23，feature/phase-one。用户要求独立启动台／设置、菜单栏入口、macOS 27 原生 Liquid Glass、共享 UI 库与中英文。三位只读 Agent 分别从交互、视觉／组件和本地化角度审查，主 Agent 独占 canonical 修改与验证。

## 本轮实现

- Launcher 保持独立 680×440 Panel；外层使用系统 regular glass，不把整块正文作为交互控件。KeyDockUI 统一字号／间距／圆角、30pt 图标命中区、44pt 底栏、分组标题、键帽与阅读表面。玻璃内部不重复叠玻璃，原生 toolbar 保留系统样式；高对比度提升自绘选中框和键帽边界。
- Settings 保持独立标准侧栏／Form 窗口，菜单栏与⌘,均可到达；应用菜单提供关于／设置／退出。从结果编辑快捷键时按稳定ID带入精确对象，同名未收藏应用不会丢失。菜单栏显示工作区保留原页，任务入口才显式切任务。
- AI 工作区工具栏常驻新建与会话草稿菜单；新建空输入请求焦点，旧草稿可返回。⌘Return运行、⌘.停止；AI动作编辑器用⌘Return保存，保留普通Return编辑多行提示词。草稿仍受32份／总字节预算和清除策略约束，不承诺跨重启保存正文。
- English／简体中文／跟随系统共用 resolver；系统语言于下次启动重新解析。LocalizedNotice保留key、原文suffix与verbatim，已有应用提示可随切换重新翻译；用户／模型／进程正文保持原文，Task／Draft提示保留和渲染均限8KiB。App注册失败通过Feature入口构造提示，避免跨bundle漏翻。
- 语言／外观和保存命令先写候选再publish，失败恢复旧字节／不存在状态。命令保存失败保留编辑器草稿。剪贴板暂停立即生效，保存或排除策略写入失败仍暂停本次采集，独立告警说明旧磁盘偏好可能在重启后恢复；成功保存才清除警告。
- 权限说明加入en／zh-Hans的InfoPlist.strings，系统权限弹窗语言由macOS决定。静态检查分别验证英中已翻译值，覆盖带suffix的noticeKey和权限说明，不在检查模式自动补英文而误报通过。

复查中另修复退出回调重入：CLI／只读Agent先登记句柄再导航，durable intent后重新检查退出围栏；回调内退出不发请求或启动命令。窗口激活检查activate／raise返回值，FocusedWindow setter不支持时读回相同AX对象才接受，不把失败当成切换成功。

## 验证与限制

最终完整回归248项：CommandCore15、ExecutionCore33、MacAdapters54、AI／Agent23、Workbench123。新增15项函数覆盖配置写前／写后失败、双语提示与原文、预算、快捷键深链接、可返回草稿、剪贴板失败暂停、同步退出重入和窗口激活返回值；参数化用例另展开。合成来源与临时目录不读取个人剪贴板／选区／凭据，不调用外部模型。原生Debug safe-smoke构建与英中静态检查分别记录，不替代UI验收。

最终证据：`.local/p1-interface-final-tests.log`、`.local/p1-interface-final-build.log`、`.local/p1-interface-final-localizations.log`及对应原生iSpec receipts；失败编译日志保留（首次测试夹具访问级别、第二次布尔#expect内throw写法，均已修正）。

当前视觉状态仍为 **PARTIAL**：本轮CUA返回Mac锁屏且自动解锁失败，未进行新版截图、真实IME、VoiceOver、深浅色、减少透明度／动态效果、高对比度、多屏与全屏复验。早前截图和基本三窗口／双语验收只能证明当时的界面。本轮不从API调用或编译推断观感达标。

真实AX、物理快捷键、Terminal交接、长期驻留、外部模型及20条质量评阅仍待验收；外部API按用户决定稍后配置。未晋升master、未创建远端、未推送／发布。
