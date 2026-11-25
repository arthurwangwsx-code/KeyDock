# 受信工具目录实现与原生复查

2026-11-25，任务25。主Agent独占canonical checkout、构建与设备，两个只读Agent评审执行和版本边界。基线master e159301；本记录为alpha.11候选，正式安装仍是alpha.10。完整产品仍PARTIAL。

## 实现与合同

CommandCore新增有界manifest、精确provider／handler合同、不可变snapshot及版本绑定。组合根仅注册随App编译的计算／单位、保存命令、文件搜索；UI和模型数据不能注册函数。三个生产路径使用同一已解析声明授权，不回退旧kind／payload分支，也不创建第二套任务、reservation或回执库。

“设置 → 内置工具”独立管理三个开关，中英说明明确新任务与在途任务的区别。开关与有效OS快捷键共用原补偿事务，只有注册及文件提交成功才发布新代次。已有快捷键偏好、定义和目录不删除。等待AX的快捷键冻结版本及完整定义revision；AI、工作流、snippet、URL和集合也有准确对象指纹。

文件查询保留原Launcher两字符／30结果和Tools一字符／50结果预算。每个结果还绑定具体report UUID；Tools入口要求旧result仍为当前report成员，不能只按路径ID升级。异步bookmark／对象验证后再核对查询、选择、目录、启用代次，随后同步调用Finder。

Workflow／Agent仅在新运行接纳前检查CLI开关，保存编辑不受禁用影响；冻结贡献／action／execution版本和命令。实际policy request与grant消费确切版本，旧任务不重解析当前目录。Agent仍保留allowlist、参数schema、逐次批准、intent和实际worker drain。计划指纹包含已安装CLI契约，版本变化需要复核，单纯启停不改变指纹。

## 工程证据与保留的失败

- 初始契约10项PASS；生产编译18＋6项PASS，测量01660b12-99bc-4b0d-977c-37080b424aac，45.640秒。
- 首两轮新增测试编译失败：Swift Testing宏内传闭包、短路表达式内await的写法不兼容。修改测试调用，未改生产并发或降低门禁。
- 第三轮暴露两个夹具假设：Agent工具按名称排序而非插入顺序；临时目录bookmark解析为/private物理路径。改为校验准确工具集合和拥有目录的物理路径，未放宽查询身份／目录验证。原失败日志与receipt保留。
- 最终定向45项PASS（33 Workbench、7 CommandCore、5 Broker／真实进程drain），测量32b44828-c10d-4470-8118-46b0dc983a56，14.720秒；receipt SHA256 54999e9d393ac4ac54f3259464d3e538ea0d68bd6d00e6509dcf35b40cea8dee。
- 覆盖计算共享／一次复制／拒绝伪造、复制失败仍优先于旧AI自动复制；CLI一次admission／intent失败零Process／在途旧参数；关闭再启用旧结果与热键、写后故障与注册失败补偿；新Workflow／Agent零接纳及定义可编辑；两者等待审批后关闭并编辑仍用旧参数；真实loopback Agent→批准→Process→工具回传；文件两个生产入口、旧result／旧查询及异步校验后代次／目录变化零Finder。

本地日志在.local/desktop/contribution-*，iSpec attempt 9881b6d8-e08e-4176-b6a2-97706ee67811。保留所有失败测量，不把整体索引审计改为全部成功。

## 原生观察

隔离Preview构建安装测量872ea749-7a84-44e6-b7cd-f4c250c45445（36.765秒）；第一轮发现Toggle辅助树缺少工具名称，补明确label／hint后第二轮9973fcaf-014f-46a5-ac9b-57011d006ef5（10.600秒）PASS。

实际观察中文浅色、英文深色工具页：三个命名开关、说明、关闭后的Tools禁用控件、返回设置入口均显示。关闭计算和CLI后正常退出、替换并重启，off状态保留；重新启用后Tools算式2+3显示5，10 km to mi显示6.21371192237 mi。文件搜索关闭时目录仍保留，Search禁用且有管理入口。最后三个开关恢复on，语言／外观恢复原Follow System。

只观察自有Preview和合成内容，未读取个人剪贴板、配置真实API或改变TCC；未使用Terminal UI。AX名称已核对，真实VoiceOver读屏、物理快捷键、多屏、完整视觉矩阵与长期负载仍未关闭。这些工程子集不代表全部日用场景或发行包资格；后续完整本机／CI／发布证据另记。
