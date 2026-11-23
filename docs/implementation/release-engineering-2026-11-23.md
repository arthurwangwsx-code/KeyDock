# 调试、安装与发行工程记录

2026-11-23。用户新增要求：整个应用在GitHub开源，本地生成并上传Release，安装替换和调试成为工程流水线。目标为`arthurwangwsx-code/KeyDock`；alpha工程交付不等于P0/P1日用验收。

## 已实现与本机证据

- 统一`make`／`scripts/keydock.py`入口；Preview使用独立bundleID、安全合成上下文、单一Debug可执行文件；正式archive要求干净完整源SHA、Developer ID和runtime。
- App/DMG公证、装订、Gatekeeper、固定四项资产与SHA256；draft回下载验签、精确tag/master来源与不可覆盖的上传策略已实现。实际公证／远端结果在发布后补记。
- 安装器核对完整App资源／权限摘要、真实签名与team、目标路径、运行实例；同卷原子交换、正常退出、保留旧包和receipt、核对双方后回退。不改配置、凭据、TCC或quarantine。
- `pipeline-check-v2`：248项Swift测试、30项Python测试、270条中英key检查与lifecycle编译通过。后续增加runtime组合flags回归，最终检查另记。
- `pipeline-owned-install-v2`：真实签名Preview在owned目录完成build1首次安装、替换到build2、回退到build1，双方资源摘要一致，第二版仍保留。
- `pipeline-preview-install-v1`：首次安装到用户Applications通过。`pipeline-live-preview-update-v1`：运行中的canonical Preview经正常退出后替换通过，备份与回执保留。
- 安装后真实启动发现Xcode Debug dylib库校验失败，修复为`ENABLE_DEBUG_DYLIB=NO`，保留runtime；重新安装后启动通过。不能用codesign通过替代实际启动。
- 真实窗口观察：启动台六行完整、Settings／Workspace独立、`⌘,`打开设置、语言来回切换时Picker文案更新、合成草稿正文和输入焦点保留、英文空状态详情换行。

原始机器日志／回执仅留在忽略的`.local`与`receipts`。公开文档只保留结果和工程边界，不上传私有诊断、钥匙串信息或个人上下文。

## 发现与回退

安装验证曾发现ditto复制到预创建目录保留0700根权限，已显式复制源目录模式并增加真实ditto回归。源码检查曾发现测试fixture意外扫描本机应用拖慢并发用例，改为注入空应用目录，未放宽断言或增加超时。

工作区最小／恢复窗口截图暴露正文裁切；额外container约束方案引发检查超时，已撤回，正常退出成功。最终采用直接NSHostingController、关闭sizing／scene桥接，AppKit NSToolbar承载普通SwiftUI控件并以contentMinSize管理尺寸；AI页与结果分层滚动。最新原生工具连续超时，视觉复验保持PARTIAL。失败日志保留，不把中间成功构建当视觉验收。

## 未完成的产品验收

外部API与真实Keychain配置按用户决定稍后配置，20条模型质量样本仍未运行；物理全局快捷键、IME、多屏／全屏、AX授权与撤销、真实Terminal交接、最低macOS与Intel尚未完整验证。CUA注入快捷键不等于真实键盘验收。视觉完整矩阵和用户评审保持PARTIAL。

最终本地`pipeline-check-final-v3`通过：248项Swift测试、32项Python流水线测试、271条中英文key、文档与lifecycle helper编译。全量日志和测量回执留在本机；正式archive将在冻结的干净提交上生成。
