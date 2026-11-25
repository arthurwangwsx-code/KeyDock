# alpha.14 发行与安装证据

2026-11-25。完整目标仍为PARTIAL。本增量完成设置摘要与原生中英子集，完整定义迁移、真实系统／模型、完整视觉和性能义务继续保留。实现与原始失败见[本轮复查](settings-summary-export-2026-11-25.md)。

## 源码与完整资格

最终source／tag为`475e31fb468f4f985166938467bcd69c566356f0`。feature分支从master `3b5934b`建立，主Agent独占写入／构建／设备，Agent只读评审，测试和评审后受控fast-forward晋升master，无worktree或复制checkout。

本机715 Swift／58 Python／744 key全部PASS，生产OCR配置的owned合成图双轮PASS。inventory694（core684／Terminal9／OCR1），SHA256 `c6d355e538159b07acdf2850edcd0fba837cff1d20097186c2e189858b24500e`。M1 Pro、macOS27.2(26B123)、Xcode27.2(27B52)、arm64；最低macOS14与Intel未获运行资格。

完整摘要`.local/pipeline/20261125T090336046835Z/check-summary.json`文件SHA256为`294be3776bc9620582023b587db841da2a80a1ddc29da5ff3c4771b0bf27a5c1`，qualification规范化摘要为`e7caea4e6f05269c478cad0842705835bfb2cb166aad5fd5534cf9560b8b7fd1`；编码范围不同，不混用。

[指定同源CI 45581812326](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45581812326)的job139093457861全部步骤PASS，含Release优化Preview；cloud-core为714 Swift／58 Python／744 key，OCR为NOT_QUALIFIED，诊断job跳过。artifact15008000446回下载95,439字节，SHA256 `ae0ed5ab5e3832b0b6cbc0e9dd5f1bb0a35db2147846674720650e26c9679b60`，ZIP及21个文件实际读取、10个阶段JSON exitCode=0通过，源码／inventory一致。

独立视觉Agent限定本页评审未发现阻塞；主按钮强调、实际Tab／VoiceOver留待完整矩阵，不以源码接线替代实际朗读。54项定向检查及英文截断修补、原始测试错误保留在上述实现记录。

## 发行流水线

| 阶段 | 测量 | 结果 |
|---|---|---|
| 完整本机 | `558706ea-0fa2-49e1-a7f4-33bb5f36adeb` | PASS，139.275秒 |
| Release构建 | `9c8566ad-d029-4f3a-8785-a78fa6c6cedd` | PASS，59.730秒 |
| 打包 | `3fae5b64-437a-455e-9ed5-4f76943de3a9` | PASS，89.149秒 |
| 发布 | `c76f179c-938b-40e6-9498-b700759925ad` | PASS，35.531秒 |
| 安装 | `ae52dbab-392b-4c64-a8c8-3cd7189fb673` | PASS，9.282秒 |

Developer ID、Hardened Runtime、team J56BFQN5PZ；App公证`619dedf1-ca98-44e9-8f78-ad2c0cc1a6dd`、DMG公证`e36a9a7d-35ae-4661-b2b5-88903d9342ed`均Accepted，装订／票据／Gatekeeper／只读挂载通过。构建仍有15条warning，含路径映射后的调试PCM及App Category缺失；hdiutil弃用提示保留，没有把构建成功写成零警告。

[公开prerelease alpha.14](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.14)于09:16:03Z公开；先draft回下载，再公开并再次校验资产。[发行审计45583779440](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45583779440)的job139100068303 PASS。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.14-macos-arm64.dmg | 3,185,972 | `e39d88c26613eb8b5b73a17db260b1c872950ccaf863303abb23f46ab6b95910` |
| KeyDock-0.1.0-alpha.14-macos-arm64.zip | 2,615,431 | `a1c9d49099a3993a96e2205ca1885134f37e2ada1a43de0698f06af0cabb504e` |
| SHA256SUMS.txt | 298 | `3eb35ef6f26aa2366494281639114aa80d28d65602ae0bbf59bb82aea6f90fb2` |
| release-manifest.json | 5,071 | `165d4a3dad439ccc1ac2e4f7180b073e97419d634138d3e5e3f1642d4c1b177b` |

## 常规安装与回退

transaction `d3c88e6a-c82a-42d2-bc8a-41af52738a78`原子替换`/Applications/KeyDock.app`，source475e31f、safeSmoke=false、签名／公证通过，bundle SHA256 `2f88d754a71be8c910d4004e2ab09777e54b285e2465dfb809c29b6870d0bb7b`。按准确路径打开常规App，实际About显示`0.1.0-alpha.14 (14)`及统一支持邮箱，不以Preview或plist代替。

alpha.13回退包为`/Applications/.KeyDock.app.keydock-backup-d3c88e6a-c82a-42d2-bc8a-41af52738a78.app`，sourcea60e386、bundle SHA256 `5440c63a64f7eb4c685356504b955514d942d551ea9333f0f6e519b593b2e6b0`；rollback_available=true，本轮没有实际回退。旧App／xcarchive／build-result重建前保留至`/Users/ai/project/macOS/KeyDock/build/pipeline/release-history/0.1.0-alpha.13-a60e386-c23ba48e-ae17-4435-ac2a-35e55d1b1e5a`，前后摘要一致，不移动已发布资产或DerivedData。

最终核验`fea279bf-72bf-4cb4-b61f-99786a2da488`PASS：两份合成导出逐字节匹配实际预览，Preview语言／外观与整个配置恢复前轮自有基线。实际Dock控制面超时且未出现在可用清单，没有通过其他UI技术绕过，Dock激活仍未验收；首次焦点切回Launcher的唯一原因也未确认。真实API按用户决定待配置，权限不绕过，完整P0–P4目标继续推进。
