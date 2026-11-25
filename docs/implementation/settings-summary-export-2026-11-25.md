# 设置摘要导出复查

2026-11-25。`feature/redacted-settings-export`从master `3b5934b`建立；主Agent独占写入／构建／设备，子Agent只读审查。候选alpha.14尚未发行，常规安装仍为alpha.13，完整产品PARTIAL。详见[摘要合同](../technical/settings-summary-export.md)。

独立Encodable白名单仅包含基础偏好、可选启动器热键及含内置定义的数量，不编码原配置。任意用户文本、ID、路径／bookmark、连接、凭据及历史均排除；未知枚举／非法热键降为固定状态，64KiB／空选择整次拒绝。摘要不能恢复应用，任务28.4完整定义迁移仍开放。

稳定审阅、冻结Data、保存attempt分别拥有身份。预览和FileDocument使用同一字节，选择变化须刷新；取消／失败分开，失败保留，保存中拒绝重入。关闭失效候选，已呈现者等准确dismiss ID释放owner，未呈现即关闭直接释放，旧回调不能影响新审阅；编辑互斥在消费pending队列之前检查。

只读审查指出历史数量与排除文案不一致、零modifier误标configured、系统dismiss绕过及未呈现关闭等待问题，均已修补并补回归。

| 定向测量 | 结果 |
|---|---|
| v1 `8e36a4f1-44b6-4236-9e76-11b8add06618` | PASS，31+4项，含CommandCore真实DesktopWorkspaceDefinitionTests |
| v2 `70ebd84f-a812-4e1c-818f-454f4ac304a8` | PASS，52项，加入编辑／会话保留 |
| v3 `9132b4cb-ecd0-40cc-a430-25797ea805c3` | PASS，53项，加入历史数量不影响字节 |
| v4 `e3285e6f-38e3-418b-951a-5b752ca8fedb` | FAIL；测试两次编码未设sortedKeys，字典顺序造成未修改断言误报 |
| v5 `f086ff8d-5f53-4df6-976c-6bffd898b28f` | PASS，53项，改用同一sortedKeys encoder，隐私断言不放宽 |
| v6 `c00745c8-e682-4ec4-99f7-96a4983581df` | PASS，54项／6 suite，含未呈现关闭与旧dismiss ID |

覆盖所有配置容器敏感哨兵、精确字段、7类选择组合、非法值／字节上限、OS端口与文件不变、冻结／失败／重试／重复提交、关闭与迟到回调、模态及pending／active所有权。744 key测量`e9ec114a-18ee-49d5-9caa-9221dcae7806`PASS。四次隔离Preview正常构建／替换均PASS，最终v4 `20507d4c-aeff-4967-b17f-d4cb7b976718`为10.028秒。

中文浅色实际审阅、取消后保留、成功、选项变化停用／刷新、空选择、Esc和重开默认值均已观察；英文深色实际保存三类选项。首版英文截图的两段范围说明被截断，已显式换行与固定垂直尺寸，修补后截图完整显示“不能恢复应用”和全部排除项；最终中文截图也通过。实际关闭设置窗口后重开可再次审阅。没有使用个人内容、真实API或更改TCC。

文件读回测量`0785fc74-d240-4a9b-bee5-9cfee40cb68f`PASS：中文311字节，SHA256 `21540c49b4640706b3254ad2b362bbafeb016c982b851cb2e325032fe857fa2d`；英文675字节，SHA256 `f664cda4f84964d200a555b98af79480580e4103c66dc545a1ea572353b0456e`。均逐字节匹配实际AX预览；语言／外观恢复system／system，Preview配置与前轮自有恢复基线一致。文件／夹具仅保留在本地忽略目录。

英文首次打开审阅时前台曾变Launcher，重开设置原审阅仍在，唯一原因未确认。另修补确定的reopen路径：可见Settings／Workspace有attachedSheet时按窗口顺序提升最内层可见sheet；隐藏／关闭中子sheet不重提，无sheet仍打开Launcher，显式热键／菜单不变。自定义处理后返回false，遵循[Apple接口约定](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:))。实际Dock控制面超时，随后可用应用清单也未找到Dock；没有重启或改用其他UI技术绕过，实际Dock激活仍NOT_QUALIFIED，编译不替代原生证据。

真实IME／VoiceOver、全视觉／辅助功能、多屏／AX、真实模型、长期驻留、性能采样及完整定义迁移仍开放。
