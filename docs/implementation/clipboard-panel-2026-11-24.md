# 独立剪贴板面板与快捷键定制

本轮从干净master `43aca85`建立`feature/clipboard-command-panels`，主Agent独占写入、分支、集成和设备；子Agent只读研究／评审。没有创建worktree、复制checkout或改动AiBox。

## 当前实现

- 三个入口统一进入独立Panel：启动台的Clipboard history、菜单栏入口及用户配置的`utility.clipboard`全局快捷键。现有配置不自动增加新的全局绑定；在快捷键设置中明确录制。
- `ClipboardPanelSession`拥有查询、选择、焦点和提交token，共用有界SQLite与`ClipboardBrowserSession`；工作区的查询／导航独立。搜索最多4096 UTF-8字节，列表只有短预览，当前一项才加载完整正文；提交重新按ID读取。
- ↑↓改变选中项并同步正文；Return请求向原应用插入，⌘Return复制，Esc返回。原生菜单和搜索控件分别保护输入法组合文本；未据此认定真实IME完整验收。
- `ClipboardPasteTarget`只取输入位置元数据，不读取原选区正文。输入目标要求非空进程启动身份、窗口、明确文本role和选区range；拒绝secure控件、Secure Input、AX或发送事件权限不足。
- `ClipboardPasteTransaction`与系统适配分离；AX验证离主线程执行，await后重查提交token与权限。原应用激活预算600ms，第三方应用激活永久撤销本次lease；迟到激活不能恢复授权。
- 所选纯文本与瞬态类型、唯一私有nonce一次写入；不读取旧板或定时恢复。最终AX检查后核对所有权／changeCount，事件只定向原进程且不重试。只能证明请求已发送，不能证明外部应用已消费／保存；跨进程消费期竞争不可能由此宣称全部消除。
- 独立宿主操作声明剪贴板写入、文本更改和应用激活三种effect；真实用户入口授权，模型不可直接调用输入能力。
- 快捷键设置新增应用／窗口／AI／命令／工具分类，默认能发现布局。具体动态窗口不能作为持久绑定；剪贴板固定行另有搜索别名，避免重复录制控件。

## 本轮实际证据

定向测试v1通过27次执行；v2通过29次（工作区21＋Mac适配8）。v3通过30次，新增异步AX校验挂起期间切到第三个应用、原目标迟到激活后仍零写入／零发送，测量`9a06258e-7398-4736-93b6-1250f5c4833c`。覆盖正文迟到、查询／选择／重开token变化、重复提交、过期条目、第三方激活、权限撤销、剪贴板竞争与独立pasteboard的瞬态／nonce校验；不把这些定向PASS当最终完整检查。

隔离Preview构建／原子替换v4通过，测量`2c6d34f4-f645-4fbc-85aa-181657a8108c`。此Preview是dirty源码构建，不是正式发行包。仅在SafeSmoke提供合成示例入口，不开启真实采集、读取个人历史／凭据或请求权限。

已实际观察：

1. 独立两栏、中文搜索“会议”得到1项与完整正文；英文KeyDock查询得到2项，Down选中合成正文。
2. 首次版本搜索框未获焦点，修补原生view连接window时的initialFirstResponder；后续重建打开即获焦点，可直接输入与方向键选择。
3. 无插入目标／权限的Preview按Return留在面板并提示可复制；⌘Return退出剪贴板面板。真实自动插入没有计PASS。
4. 13个窗口布局在独立分类可见；录制Preview专用⌃⌥K与剪贴板⌃⌥V后注册成功，重建重启后仍显示保存的值。CUA注入已录制的组合未观察到系统级唤起，因此物理全局热键仍待验收；不把注册状态等同于实际按键通过。
5. 中文浅色／英文深色已查看渲染；修复标题语言不同步和深色预览突兀矩形，圆角半透明阅读层重建后实际观察。语言、外观已恢复为跟随系统。
6. 保存剪贴板别名`clips`，固定配置行与别名输入可见；其余AI／工作流合成数据保留，未启用个人采集。

最终审查另发现无AX插入目标时，Copy／Esc原应用身份被丢弃。现将presentation的returnTarget与插入目标分开保存，查询变化保留返回身份，关闭清理；从Launcher继承时若其最初快照尚未就绪，仅保留复制／返回路径，不重新读取较晚的输入位置。旧源`1a5d0e7`完整检查399 Swift／43 Python／524 key及Release构建通过，但不作为此修补后的发行资格，修补提交需重新检查。

## alpha.5最终发行证据

| 范围 | 结果与绑定 |
|---|---|
| 源与tag | `7541c25c1893c7e8237d87280525ec4c48702407`，受控fast-forward master后建立并回查`v0.1.0-alpha.5`；后续证据doc另从master的chore分支提交 |
| 完整本机＋Release | PASS，400 Swift执行（390 core＋9 Terminal＋1 OCR）、43 Python、524中英key、50文档；测量`86372456-e6ae-4d16-bc81-5a3437507857`，14:35:16Z–14:41:52Z |
| 清单／OCR | 379个声明ID及21次参数化额外执行；生产accurate／revision3两轮真实识别，macOS27.2 arm64／Xcode27.2；资格摘要`8e0efea04ebaed857f55893f23e30b067d9f7455dd2bba9931f1ccf87add5d73`封入App与manifest |
| 同源core CI | [45415628626](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45415628626) PASS，399 Swift及优化版Preview；云端系统OCR为NOT_QUALIFIED。旧源1a5d0e7运行因修补push按concurrency取消，未伪报为最终PASS |
| 公开性 | 276候选及最后4文件delta静态复核PASS，无个人内容／凭据／新增依赖；不替代实际资产审计 |
| 公证与包 | Developer ID／Hardened Runtime、App／DMG公证装订、Gatekeeper及只读DMG内部App与ZIP一致性PASS；测量`b86e69d5-c46a-44bc-8155-2d9f4abfe398`，14:44:07Z–14:45:35Z |
| Apple公证ID | App `b58849fb-2d04-4a45-992d-7d5aebcc6267`；DMG `c57aee2c-0848-437b-a9f5-2d21342b7943`，均Accepted |
| 正式安装 | 运行中alpha.4正常退出，原子替换为alpha.5；测量`7c6287d7-7038-42a0-adfc-c884d7cd9fb4`，14:46:34Z–14:46:46Z；未force kill／改TCC |
| 公开发布 | [GitHub alpha.5](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.5)，测量`380e2bec-1c54-4719-9746-3bf34ca79608`，14:49:14Z–14:50:02Z，draft回下载后公开prerelease并再次核验 |
| 独立公开回下载 | PASS，测量`345dff65-bff4-48f7-9940-e43634d184d4`，14:50:50Z–14:51:11Z，tag／源／资格／签名／摘要及DMG内部App一致 |
| GitHub资产审计 | [45418462685](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45418462685) PASS，精确tag下载核验；不代表真实插入或物理键盘验收 |

发行资产保留于`build/releases/0.1.0-alpha.5`：ZIP SHA256为`e5ffad61d939a59085d36f2f7bd39811d488ccacc38f495111bc7ec6f25025c3`，DMG为`a6a3d5f57cdd2d3d99768f7797621e651cc62d94fe6dda628dbf2d7697347ae5`，manifest为`5f4a029688d8e09f8e78735ff3339d126d4ef937451df5f7eb4c2093a44bb852`。旧alpha.1／2／4及本地未公开alpha.3字节保留。

安装事务`bfb039fa-3c73-4ccd-8da6-70d83b7eb212`，回退凭据在本机`.local/pipeline/20261124T144634404642Z/install-receipt.json`，备份是`/Applications/.KeyDock.app.keydock-backup-bfb039fa-3c73-4ccd-8da6-70d83b7eb212.app`。可用`python3 scripts/keydock.py rollback .local/pipeline/20261124T144634404642Z/install-receipt.json --quit-running`恢复alpha.4；本次未执行回退。正式App已实际启动，「关于」显示`0.1.0-alpha.5 (5)`；隐私页仍显示需要辅助功能权限，未打开个人历史或更改权限。安装App的bundle摘要为`bb707fc94297cb319c5be4bf188bfe9a9b20fa3a6c59d73f2cb0fc99722cd96f`。

## 持续建设义务

完整目标保持active：真实原生／浏览器输入目标的插入、AX与事件权限授予／撤销、Secure Input、物理全局热键、真实IME、VoiceOver、不同显示设置／屏幕及完整视觉矩阵待验收。窗口循环／最小化、应用行为定制、剪贴板多项合并／顺序插入、主动作偏好、更多竞品常见能力及原P0–P4继续推进。真实API按用户决定稍后配置，AI质量与第三方协议仍需实际验证。当前正式版／签名公证／公开发行状态见[状态总账](../status.md)。
