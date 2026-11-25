# alpha.13 发行与安装证据

2026-11-25。完整目标仍为PARTIAL。本增量完成任务27的工具生命周期工程闭环与原生中英子集，不替代真实AX、物理热键、IME／VoiceOver、外部API、全视觉或长期性能验收。

## 源码与完整检查

`fix/saved-tool-lifecycle`从master `0f89927`建立，最终源／tag为`a60e3865352ac2acbbd63fa048c4157d5872b2b9`。只读Agent复核确认待审命令门禁修补解决前次P2，没有发现本增量新的阻塞问题。完整检查与评审后受控fast-forward晋升master，无worktree或共享并行写入。

完整本机测量`43623d4c-01bc-48da-a8a5-74ea128d0963`PASS，185.649秒：702 Swift／58 Python／729 UI key，原配置系统OCR两轮均识别owned合成图。声明inventory681（core671／Terminal9／OCR1），SHA256 `27f20766de3cdf91be016c5eaecc83d5b45dee93c9975e28dcd9cfe8e1706d71`。机器为M1 Pro、macOS27.2(26B123)、Xcode27.2(27B52)、arm64；最低macOS14及Intel未验收。

本机摘要`.local/pipeline/20261125T080317428064Z/check-summary.json`文件SHA256为`c7b1197a61d7557c9c71e113a995d1fc246a93bff14d9375b3b4956e4ddca317`，qualification规范化摘要为`c7d9662b726324be66a24b4a2b0f3d49875c0a39ab14f923e763ccb96135343a`。两者编码范围不同，不能混用。

[同源feature CI 45572982035](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45572982035)的job139063916721全部步骤PASS，含Release优化Preview。cloud-core为701 Swift／58 Python／729 key，系统OCR明确NOT_QUALIFIED，诊断job跳过。[同源master CI 45574345393](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45574345393)亦PASS。

CI日志artifact15003193267共93,814字节，SHA256 `8e8b6043d29b100c14395d1298051a2a01e0926ff3523c2bd511c11822d30044`。连接器下载链接返回403后改用gh下载同一ID；ZIP校验、21个文件实际读取及10个阶段JSON exitCode=0均通过，源码／inventory与本机一致。原生／故障及三次测试源错误记录见[任务27复查](saved-tool-lifecycle-2026-11-25.md)，没有覆盖失败记录。

## 签名、公证与公开回下载

| 流水线测量 | 结果 |
|---|---|
| Release构建 `6ae333ea-233d-4875-bd59-3a27550cf613` | PASS，219.952秒 |
| 打包 `c1e41e11-0681-4a2d-83c9-9513d8ba5a3b` | PASS，91.244秒 |
| 发布 `3e98c15d-c2f9-4bca-aab3-35fca7063d31` | PASS，32.961秒 |
| 安装 `f40aaf97-7a36-4b9e-bd6c-f590884db020` | PASS，11.222秒 |

Developer ID／Hardened Runtime、team J56BFQN5PZ；App公证`964a1af5-625c-49d4-a624-60ca1c8cf502`、DMG公证`0d1d8bbd-4f2c-4fb7-9844-b714bc80b586`均Accepted。App／DMG装订、票据、Gatekeeper及只读挂载核验通过。构建仍有15条warning，主要是路径映射后的调试PCM、未依赖AppIntents及尚无App Category；构建成功不代表这些警告消失。hdiutil旧语法弃用提示亦保留。

[公开prerelease alpha.13](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.13)于08:22:22Z公开。流水线先创建draft，回下载校验后公开，并再次验证公开资产。[发行审计45575690361](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45575690361)PASS。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| ZIP | 2,582,518 | `94c388c2a6146491e2293b8249ff26687984b04d2de27ca6d2cd4a0c433aaec2` |
| DMG | 3,147,926 | `69f0a6635692f4dede75d19a7097ef99ebb52eaaac460bec7e4ca99efab9427f` |
| release-manifest.json | 5,071 | `591b14983e9c8adee6172e23f8fc0e7eadfc2a6f8045858ce1a0bcb09743e779` |
| SHA256SUMS.txt | 298 | `e0bc491425f77988816086c3d8a762e3f8caad70b33c2b59f1909289428e7ef2` |

## 常规App与回退

原子安装transaction `680cbec6-576d-40c3-88b6-edd83e06405d`替换`/Applications/KeyDock.app`，准确源为a60e386、safeSmoke=false、签名／公证通过，bundle SHA256 `5440c63a64f7eb4c685356504b955514d942d551ea9333f0f6e519b593b2e6b0`。通过准确App路径启动后，实际About显示`0.1.0-alpha.13 (13)`和统一支持邮箱，不以Preview或plist代替此观察。

alpha.12直接回退位于`/Applications/.KeyDock.app.keydock-backup-680cbec6-576d-40c3-88b6-edd83e06405d.app`；原源d99fee8、bundle SHA256 `9bd702dfd4f13e4f7315c6130d33f2c2e0248ffe580b6d71d9de5e3c87780b99`，rollback_available=true，本轮没有实际回退。旧alpha.12 App／xcarchive／build-result三项在重建前移动至`build/pipeline/release-history/0.1.0-alpha.12-d99fee8-731d87b3-eeb2-4204-8d4a-1e0acddf6bcf`，前后摘要一致，未移动已发布资产或DerivedData。

下一工程缺口是脱敏配置导出与UI／驻留性能采样。完整配置含任意用户文本，不能靠正则承诺脱敏；查询基准不包括真实屏幕呈现，不能代替150ms热唤起验收。真实API按用户决定稍后配置，辅助功能授权问题仍独立等待用户设置，不绕过权限。
