# 可选任务材料基础层与捕获接线

2026-11-26；主Agent单写canonical checkout，在从master `d2c9a01`创建的`feature/task-material-retention`实施。三位Agent只读评审存储／运行入口／安装合同，没有修改AiBox、创建worktree或操作个人数据。本增量不是原生保存功能或完整P0–P4验收。

| 范围 | 状态 | 已有证据与限制 |
|---|---|---|
| 独立正文格式／存储 | PASS（定向） | 出生key、独立material UUID／revision、header-only、按需payload校验、一次性CAS、固定目录FD与锁身份、原子持久及容量；Swift／Python读取同一合成golden |
| 删除与恢复 | PASS（独立actor）／PARTIAL（App接线） | 无正文删除意图、pending遮蔽、部分残留、重启继续删除、TTL与捕获inventory CAS；尚未接App启动、定时维护及history正文清除 |
| 未来运行捕获 | PASS（定向）／PARTIAL（产品） | 四类入口冻结准确输入／CLI无独立输入，同步Workflow成功端口，worker对象与birth绑定，停用先撤销，32MiB联合预算；无公开设置开关，AI／Agent完整真实服务验收仍独立 |
| 安装数据协议 | PASS（单元／隔离签名资格） | schema2独立taskMaterial readers/writers；schema1无材料reader，header/control-only扫描及实际交换／补偿重查。签名Preview实际交换中，正文／tmp／pending拒绝旧能力、清空后回退通过；不冒充真实alpha.19运行 |
| 原生审阅与输入复用 | NOT_RUN／未接通 | 保存／查看／删除modal、actual-dismiss、输入回填票据和中英明暗视觉矩阵仍开放 |
| 发行与安装 | 未发行 | 开发版本升alpha.20／build20；正式App与公开资产保持alpha.19，不用新基础代码重写历史发行能力 |

## 定向验证

共享存储门禁8GiB租约内串行执行，iSpec apply attempt为`9881b6d8-e08e-4176-b6a2-97706ee67811`。

- `task-material-capture-v4`：65项Swift（43材料／捕获、17 RunStore、5 Workflow成功端口），exit0，receipt SHA256 `31dd2a739d56e87f169dcddd61d98ced8897ca0aaf1dc285f75f280639120ea6`。含begin实际挂起时撤权再开启、可选预算不足但真实任务完成、旧配置默认关闭、输入Unicode字节及空值、成功边界乱序、锁／临时／删除目标置换、权限ABA与清除不复活。
- `task-material-python-compat-v3`：137项Python全套，exit0，receipt SHA256 `ea7802b69c0c0e42d0e6c192eb79320b3d8d13f2c305a4d0f91e0a85f592ae95`。含header读取字节计数、目录迭代在limit+1停止、三类调用库兼容、材料阻止旧reader、清空后放行、quiesce后变化和交换后补偿拒绝。
- 本轮日志位于`.local/desktop/task-material-*.log`，正式measurement receipts由iSpec维护；不包含个人正文／剪贴板／密钥。

保留此前失败：编码膨胀的错误分类、增加回调后旧trailing closure绑定、测试宏递归展开、Foundation将`/private/var`还原为`/var`导致严格NOFOLLOW拒绝、actor调用置于断言autoclosure等。修补未放宽生产路径／容量／执行门禁。早期begin暂停夹具误在Store初始化消费暂停，虽绿测但不证明目标交错；已改为显式arm、确认等待和无超时断言，最终交错测试实际约40ms收口。

评审发现并修补：锁目录项置换、正文临时文件在rename前换绑、commit未执行rename却报告成功、删除前置hook后换绑、新旧正文共存预算，以及Python目录先完整listdir才检查上限。均保留针对性回归；静态评审不作为实际签名／GUI资格。

## 干净源与签名资格

精确源`d8ae7ca2ded8dc0eb6ebd5e782b8d0ed0715d3b0`已推送公开feature分支；master保持`d2c9a01`，本增量尚未晋升或发行。

- 完整本机`task-material-foundation-full-check-v1` exit0，94.45秒，receipt SHA256 `bcb7590b57b4cee21c7db55d2574e395e80532929839dc7716b3e5a67cecc629`。898 Swift执行工具计数、137 Python、876中英key、生产accurate／revision3／自动语言／纠正／支持CPU OCR两轮通过。测试inventory877声明与参数化实际次数分别记录，不能互换。
- 优化Preview `task-material-preview-build-v1` exit0，79.01秒，receipt SHA256 `9fcbfc275ca0821355ea120a36026cd959f9ba38b21a132785ff2f1494bb1075`。App为alpha.20／build20、ReleasePreview、干净d8源，签名资源声明schema2、invocation[1,2]与taskMaterial[1]。这是隔离ad-hoc Preview，不是Developer ID发行包。
- `task-material-signed-install-v1` exit0，12.61秒，receipt SHA256 `88a997dffd35cf0f689cc7cd9d44d9cce19e2ced4f81fe914503e0cd9ea3a28b`。owned随机目录中三份签名Preview及合成运行域，实际安装／替换／回退、正文／临时文件／pending拒绝且App和数据字节不变、清空后允许回退均通过；未启动App、未读正常运行数据域。补偿失败属于单元故障注入资格，非本签名探针覆盖。
- 同源[文档CI 45706573453](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45706573453)已PASS；[原生CI 45706573307](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45706573307)仍运行中，终态另行记录，不提前标为通过。
- 当前attempt completed measurements的receipt摘要／身份审计exit0；全局历史未完成记录继续保留，因此不把本次局部审计写成全历史完整。原正式App metadata仍为alpha.19(19)、源e488、bundle摘要`53ef17286197d7dce8b9ae997ef81deaf8d211baeda85699c393a3dd24caafa4`。

## 后续门禁

先完成原生审阅与App维护接线、按需复用的完整身份票据、额外读取／审阅缓冲预算和双语文案，再分别验证原生中英明暗／长正文／失败／取消／重启。完整本机、同源CI、签名能力资格和新候选协议的真实App／DMG公证发行均须独立留证；当前不关闭35.2–35.4、35.6–35.7或完整产品验收。
