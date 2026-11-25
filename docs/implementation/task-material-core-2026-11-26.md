# 可选任务材料基础层与捕获接线

2026-11-26；主Agent单写canonical checkout，在从master `d2c9a01`创建的`feature/task-material-retention`实施。三位Agent只读评审存储／运行入口／安装合同，没有修改AiBox、创建worktree或操作个人数据。本增量不是原生保存功能或完整P0–P4验收。

| 范围 | 状态 | 已有证据与限制 |
|---|---|---|
| 独立正文格式／存储 | PASS（定向） | 出生key、独立material UUID／revision、header-only、按需payload校验、一次性CAS、固定目录FD与锁身份、原子持久及容量；Swift／Python读取同一合成golden |
| 删除与恢复 | PASS（独立actor）／PARTIAL（App接线） | 无正文删除意图、pending遮蔽、部分残留、重启继续删除、TTL与捕获inventory CAS；尚未接App启动、定时维护及history正文清除 |
| 未来运行捕获 | PASS（定向）／PARTIAL（产品） | 四类入口冻结准确输入／CLI无独立输入，同步Workflow成功端口，worker对象与birth绑定，停用先撤销，32MiB联合预算；无公开设置开关，AI／Agent完整真实服务验收仍独立 |
| 安装数据协议 | PASS（单元）／PARTIAL（签名资格） | schema2独立taskMaterial readers/writers；schema1无材料reader，header/control-only扫描及实际交换／补偿重查。签名Preview的真实文件交换尚待执行 |
| 原生审阅与输入复用 | NOT_RUN／未接通 | 保存／查看／删除modal、actual-dismiss、输入回填票据和中英明暗视觉矩阵仍开放 |
| 发行与安装 | 未发行 | 开发版本升alpha.20／build20；正式App与公开资产保持alpha.19，不用新基础代码重写历史发行能力 |

## 定向验证

共享存储门禁8GiB租约内串行执行，iSpec apply attempt为`9881b6d8-e08e-4176-b6a2-97706ee67811`。

- `task-material-capture-v4`：65项Swift（43材料／捕获、17 RunStore、5 Workflow成功端口），exit0，receipt SHA256 `31dd2a739d56e87f169dcddd61d98ced8897ca0aaf1dc285f75f280639120ea6`。含begin实际挂起时撤权再开启、可选预算不足但真实任务完成、旧配置默认关闭、输入Unicode字节及空值、成功边界乱序、锁／临时／删除目标置换、权限ABA与清除不复活。
- `task-material-python-compat-v3`：137项Python全套，exit0，receipt SHA256 `ea7802b69c0c0e42d0e6c192eb79320b3d8d13f2c305a4d0f91e0a85f592ae95`。含header读取字节计数、目录迭代在limit+1停止、三类调用库兼容、材料阻止旧reader、清空后放行、quiesce后变化和交换后补偿拒绝。
- 本轮日志位于`.local/desktop/task-material-*.log`，正式measurement receipts由iSpec维护；不包含个人正文／剪贴板／密钥。

保留此前失败：编码膨胀的错误分类、增加回调后旧trailing closure绑定、测试宏递归展开、Foundation将`/private/var`还原为`/var`导致严格NOFOLLOW拒绝、actor调用置于断言autoclosure等。修补未放宽生产路径／容量／执行门禁。早期begin暂停夹具误在Store初始化消费暂停，虽绿测但不证明目标交错；已改为显式arm、确认等待和无超时断言，最终交错测试实际约40ms收口。

评审发现并修补：锁目录项置换、正文临时文件在rename前换绑、commit未执行rename却报告成功、删除前置hook后换绑、新旧正文共存预算，以及Python目录先完整listdir才检查上限。均保留针对性回归；静态评审不作为实际签名／GUI资格。

## 后续门禁

先完成原生审阅与App维护接线、按需复用的完整身份票据、额外读取／审阅缓冲预算和双语文案，再分别验证原生中英明暗／长正文／失败／取消／重启。完整本机、同源CI、签名能力资格和新候选协议的真实App／DMG公证发行均须独立留证；当前不关闭35.2–35.7或完整产品验收。
