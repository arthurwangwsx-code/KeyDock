# DesktopReview身份基础层复查

2026-11-26，开发分支`feature/desktop-review`，基于master `1e89f56`。对应任务36.1；完整合同见[技术方案](../technical/desktop-review.md)。主Agent独占写入和测试，另一Agent只读评审。

## 当前结果

| 项目 | 状态与边界 |
|---|---|
| scope身份基础层 | PASS：固定Review／fixture ID、构建绑定DTO、私有根／精确marker、逐层no-follow FD、单写锁、companion文件摘要、进程出生与路径检查；观察到失效后永久撤销 |
| 文件生命周期 | PASS：哈希在后台worker执行；取消等待实际worker结束才释放锁。目录合法增长不撤销owner；不可变文件严格比较；配置仅写入固定Data叶节点 |
| 定向回归 | PASS：Swift Testing报告12项测试，含多组参数；覆盖链接／FIFO／hardlink／权限／大小／schema、路径、替换、实例变化、配置越界、重启空辅助session、失败和取消释放 |
| 独立评审 | PASS（静态）：有界hash gate建议已落实，未发现剩余实质阻断；评审未运行测试 |
| 原生产品接入 | PARTIAL：尚未接入App、Workbench策略、配置／窄设置、签名companion或启动器；36.2–36.5继续开放 |
| 正式产品 | PARTIAL：发行／安装仍为alpha.20；不关闭10.1–10.2、真实插入、实体键盘、完整视觉或原P0–P4 |

## 保留的失败与修复

首轮`desktop-review-scope-v1`编译成功，但有效夹具在摘要前也被拒绝，9项测试报告13个issue。独立Swift探针确认：Foundation的`standardizedFileURL`会把真正的`/private/var`物理路径改成`/var`，因此不能用于要求物理路径原样不变的词法判断。

修复采用绝对路径／字节／组件上限及纯字符串重组，拒绝空组件、`.`和`..`，继续逐层`O_NOFOLLOW`；没有改成自动解析调用者链接。v2的10项测试通过；随后加入hash失败释放、重启隔离和有界gate，最终v3的12项测试通过。首轮失败、探针和后续结果均保留，没有覆盖失败回执。

本地证据：`ispec/changes/keydock-foundation/receipts/desktop-review-scope-v1.json`、`desktop-review-path-probe-v1.json`、`desktop-review-scope-v2.json`、`desktop-review-scope-v3.json`，对应日志在`.local/desktop/`。测试使用合成文件及注入的进程身份，没有启动真实companion、读取真实剪贴板或授予TCC。

## 下一接入点

Workbench需显式接收scope，关闭常规采集、凭据、一般执行和恢复入口，并只开放历史复制／受限插入。App随后增加独立Review身份和窄设置，工程CLI创建签名合成宿主、启动收据及精确正常退出。完成这些接入后才开始真实目标消费和快捷键的原生验收；scope不是同UID恶意进程沙箱。
