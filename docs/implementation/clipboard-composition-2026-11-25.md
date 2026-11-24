# 有序剪贴板合并增量复查

日期：2026-11-25（本地），测量使用UTC。`feature/clipboard-composition`从master `2fe35b6`创建，主Agent独占写入／提交／设备，子Agent仅只读审查。冻结源`59d1680be17fb5713cf79834fbceec3df496ed27`已受控fast-forward并以alpha.7公开和安装；完整产品继续PARTIAL。后续chore分支只补齐证据，不修改tag或发行字节。

## 当前实现与验证

| 范围 | 结果 | 证据与边界 |
|---|---|---|
| 合并模型与存储 | PASS（定向） | 20项、UTF8含分隔符1MiB、单事务保序读取、缺失／过期整批拒绝；不先加载20份正文 |
| 清单与准确预览 | PASS（定向及原生子集） | 跨查询保留、前后移动、空行分隔、Shift-Return已观察；提交前比较实际UTF8，正文变更先重新查看 |
| 单次提交与取消 | PASS（合成） | 重复提交只触发一次合并插入callback，偏好变更撤销等待请求，沿用既有paste目标／nonce／激活围栏；真实产品自动插入仍待权限与实机矩阵 |
| 主动作与偏好 | PASS（已观察子集） | 设置Return为复制后，底栏提示与实际复制一致；退出重启及Preview替换后保留Copy／Blank line；菜单共用alternate解析，未声称物理全局热键通过 |
| 实际合并复制 | PASS（合成原生） | Return复制英文＋空行＋中文，随后在合成NSTextView用标准Select All／Paste，实际正文与预览完全一致；这是复制结果及手动粘贴验证，不是KeyDock自动插入验收 |
| 视觉与双语 | PASS（已观察子集） | 中文浅色／英文深色的面板、合并清单与设置；英文尺寸单位误跟系统中文已修补并实际复查为bytes；完整四组合、IME、VoiceOver／对比度仍待验收 |
| AI复制兼容 | PASS（定向） | 普通结果保持非瞬态、历史／插入保持瞬态；复制失败不将完整模型结果、usage与成功回执误写成请求失败 |
| 全量与发行 | PASS（工程） | 当前干净源完整检查、同源CI、签名／公证、安装、公开回下载和独立资产审计通过；没有复用alpha.6资格，完整产品仍PARTIAL |

## 测量与修补

初次命令直接调用PATH中的swift，选中本机自定义Swift6.3.3，与当前SDK参数`-target-arch-variant`不兼容。该次失败`f12f8343-fb79-46f2-a9fa-4acca193b651`保留；确认精确命令后中断该测试进程，随后统一使用流水线一致的`xcrun swift --jobs 2 --no-parallel`。

- `da52543b-6c00-4e87-972e-71e2aaa51def`：40项相关执行通过，17:42:39Z–17:48:50Z，包含首次更换工具链后的重新编译。
- `66365b34-b9cb-4f2b-937a-68f90fd93b48`：13项定向执行通过，包含新增的重复合并提交只调用一次及抛错writer传播；与前项有重叠，不能相加作为唯一用例数。
- `2d99f025-dddd-4a72-b542-f1ed514049bb`：42项AI／剪贴板执行通过，成功loopback生成后令复制writer抛错，核对完整输出、completed、usage succeeded、成功AI回执及仅一次HTTP请求。隔离pasteboard检查普通类型可供显式输入，外部敏感类型规则未放宽。
- `9d96245b-0358-4f40-82fd-ebc5eb65508c`：583个中英文UI key及55篇文档、13项固定参考、34条要求／74个场景／92项任务通过；后续增加本证据页需重新检查文档总数。

只读审查捕获并修补：原生菜单仍按单选启用／固定标题；Unicode规范等价掩盖不同UTF8字节；全局瞬态复制阻断后续AI输入；自动复制失败误报模型失败。均保留对应回归。AiBox仅作既有设计参考，本轮没有迁入其私有源码、凭据或个人媒体，无新增第三方依赖。

## 原生观察与测试宿主

统一debug入口构建并原子替换独立Preview；最新测量`158105c3-63d1-45d1-b4b3-f929054f58c0`通过，源记录为`2fe35b6` dirty，binary摘要`d78d0726455cf4fb359a8fc831c9497453f390a6c9f3d8708bbcf1e4663ef832`。这只能绑定本次开发宿主，不是正式发行资格。

原合成宿主只有Quit菜单，标准粘贴未改变正文；补齐显式Cut／Copy／Paste／Select All菜单后，相同键盘操作实际写入了完整合并内容。新宿主通过`make desktop-fixture`在全新目录构建，测量`10c40575-1129-4943-9390-65b1847d51d1`，binary摘要`51a967f9a9fac0d2b94209fa623b18d5430258b55f163160e33b3c7cfec67e46`。旧App与证据保留，未覆盖未知用户应用。宿主只响应明确编辑动作，不采集或联网；旧失败不计作产品插入失败或成功。

视觉观察使用真实渲染及AX状态，没有把截图字符串检查当作对比度或辅助功能验收。结束后Preview恢复Return插入／换行分隔符，语言与外观恢复跟随系统，合成宿主经正常退出。没有读取个人剪贴板／截图／终端历史，没有配置真实API或授予TCC。早期54份测量收据已核对，后续发行审计继续增补；阶段仍运行。

## 宿主失败、恢复与完整资格

预检测量`5a263deb-d596-4899-8c2c-4c4e2ae13f96`因仅余1.10GiB停止，没有执行测试或复用旧资格。确认没有活动构建后，只清理本工程15个忽略的中间产物、模块／SDK缓存和索引；保留源码、Products、发行包、安装备份和日志。实际可用空间由1,056,860KiB变为2,184,980KiB，约回收1.1GiB，收据保留于本机。

后续测量`9bede586-3723-4250-ae9e-98de064946d8`在编译中遇到ENOSPC，未生成资格；其他工程当时仍在编译，不能将整机空间变化都归因于本工程。空间回升后，测量`afcad00d-1289-4b53-a87f-ade68b65f0b6`通过462项core与9项Terminal，但最终生产OCR在93.147秒失败：`TextRecognition.CRImageReaderError code1`及`e5rtError(...,13)`。该次完整资格为FAIL，不因前471项成功而改记PASS。

生产OCR、资格测试与release_quality.py相对alpha.6无变更。保持accurate／revision3／自动语言／纠正及支持阶段CPU分配，未改OS服务或权限。空间回升至约6GiB后，独立测量`d59c80fa-1843-4e3c-82db-e39c676a5d2f`双轮通过，随后完整测量`e3dee961-a0a9-4d94-af44-3609ab20bd16`在18:24:46Z–18:27:44Z通过472项Swift（core462＋Terminal9＋OCR1）、46项Python、583条中英文UI key、文档及lifecycle helper。451个声明ID与21次额外参数化执行分开计数。

当前本机资格为macOS27.2／26B123、Apple M1 Pro arm64、Swift6.4.2、Xcode27.2／27B52、SDK27.2。两轮真实识别的fixture摘要仍为`06db6e05ce33913ef1ec983f48496c89ff7112b5f2a1ab26dd782f349499e161`，hasKeyDock／hasSynthetic／usedOCR均true，规范化资格摘要为`9f708d24234061e9480c3add628a4c620bb324d27b1e265970074d2d06745bcc`。

没有找到这组内部错误的公开根因映射，不能把e5rt的13当成POSIX EACCES或将内部code1当成取消。空间、内存、并发工作负载只能作为调查线索。当前设备选择遵循[Apple公开计算设备接口](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice%28_%3Afor%3A%29)，如复现可记录合成输入摘要、支持／分配设备、失败阶段、递归NSError域／代码链和资源时间线，遵循[Apple诊断指引](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)避免个人正文。独立PASS没有被拼接成完整资格；本版使用后续整套成功记录，早前失败保持原样，OCR可靠性和长期性能仍待验收。

## 签名、公证、安装与公开发行

同源[core CI 45456156935](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45456156935)成功，云端OCR继续NOT_QUALIFIED。Release构建`84a2bdee-4509-4819-b3a9-6b182d43fde1`在18:28:36Z–18:32:15Z归档及Developer ID签名通过。

打包测量`96061f25-c501-4872-a66b-99166c09aa97`通过；App公证`c043708a-71c5-4b55-b69d-43efa1ec0c02`与DMG公证`40f3bfa8-b4e9-4408-91a0-94e9a26efc59`均Accepted。装订、Gatekeeper及只读DMG内部App一致性通过。

安装`a5641ba8-b638-4e75-a66a-5b28df22ced4`与发布／实际回下载`8eeadccd-7c48-4074-8b6a-f022e7b012db`均通过。[alpha.7](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.7)在18:37:17Z公开为prerelease，正式App已实际启动并在「关于」显示`0.1.0-alpha.7 (7)`。Alpha.6及回退receipt保留，未force kill或改TCC。

ZIP摘要`2bdf120ec215056ed14d0eb771f2e581e931f5285522483bdac1ceebf20a65fa`，DMG摘要`57747863592d974cf2a46c435d9cb956b15a24bd5b69fa067eb4530003782543`，manifest文件摘要`1ba1d0925755e036837c845c791c81321c6525612945224bcac985114d5b3780`。安装bundle摘要`abc2863f699b7914e3c2223d63576f0d9cf6046514ba31a20e0a396fbed54efb`。独立[资产审计45461512603](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45461512603)已通过，不冒充OCR或真实自动插入验收。

发行证据文档检查`7a680721-beb6-4625-8aa2-84075048f43e`通过56篇文档、13项固定参考、34条要求／74个场景／96项任务及583个中英UI key。当前apply attempt共65份测量收据均已核对实际文件摘要，59次exit0、6次失败全部保留，阶段仍运行。全局metrics中的两份旧格式历史记录没有重构启动或伪造成功，不将本轮收据核对表述为全历史审计完成。

## 仍需推进

完整四组合、IME、VoiceOver／对比度、真实自动插入／窗口／物理热键、最低系统、长期驻留及真实模型质量仍未关闭。后续静态审查还发现输入编辑器AX名称、计划显示时区、Launcher视觉／AX副标题及只读文本规范等价同步需要继续复查，已列任务13；不将Catalog完整或本轮发行等同完整UI验收。
