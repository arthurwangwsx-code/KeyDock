# 工作流与MCP移除复查

2026-11-25，alpha.17已公开并替换正式App。任务31承接“完整功能及自定义闭环”，修补删除后的引用、旧稿与异步收口；合同见[来源移除](../technical/source-removal.md)，干净源CI／公证／回下载／实际About17见[发行证据](alpha17-release-2026-11-25.md)。

## 工程与定向结果

首次两次编译通过；新增25项测试，加上配置导出、保存反馈、MCP预算及孤儿偏好共54项／8套件定向回归通过。最终回执`receipts/source-removal-targeted-v4.json`，measurement `a96410d6-900c-41b4-9cba-3060d7d0bca5`，22.014秒；测试执行部分1.379秒。

06a271c＋WIP候选完整本机检查760 Swift／74 Python／789 key PASS，原生产OCR配置双轮PASS；739 inventory／729 core／9 Terminal／1 OCR。measurement `283d1c0e-fd23-4375-84d0-b4c8e428a7c7`，89.725秒，目录`.local/pipeline/20261125T125008302959Z`。这是候选工程证据，干净发行源需另行资格；DebugPreview构建／隔离安装measurement `922542c3-c476-4704-8cc8-abfbf72a12a2`，33.894秒。

- 权威调度账本有禁用引用而UI缓存为空，仍阻止移除；集合与Agent来源／仅残留命名空间工具同样阻止，取消或过期无连接／凭据副作用。
- 主配置跨await ABA、调度定义ABA、共享owner双向竞争及Published同步重入拒绝；原指纹区分NFC／NFD实际字节。
- 写前／写后失败保留原文件与定义，工作流候选／原注册补偿真实进入注入端口；MCP失败仍暂停并关闭连接，owner与busy收口。
- 删除后旧Workflow和MCP编辑稿不能复活原ID；新建生成新ID。稳定审阅／旧按钮／窗口关闭／已结束捕获的迟到结果不能污染新呈现，失败保留审阅可重试。
- 在途真实WorkflowRunner等待手工输入时删除定义，旧任务仍按冻结步骤完成；旧catalog item被拒绝且不能写回recent。
- owned内存MCP客户端验证旧cleanup不清新目录、旧启用保存不能覆盖较新Disconnect、非合作迟到resource读取不提交正文、shutdown真正等待已提交清理完成。此范围不等于独立服务兼容性。
- 导入文本、AI草稿revision和已有历史输出保留；Agent可离线移除失效引用；孤儿Workflow偏好仅经显式修复。

首轮52项定向失败记录保留：合成传输漏modern server/discover、快捷键测试未提供合成注册端口，以及旧按ID删除断言仍期待原写入路径。补齐宿主与准确API覆盖后53项通过；新增在途／recent回归后54项通过，再以明确任务handle等待和可释放gate强化负面断言，v4再次54项通过。未将首轮失败改写为产品PASS。

只读评审发现的真实竞态已修补：旧MCP保存在cleanup await后无条件清除sessionDisabled，会覆盖期间用户Disconnect；现在发布启用意图在await前，owner继续阻止新调用，较新撤权保留。另一原缺口是await后按ID清目录，已改为先移除旧缓存再await。所有共享代码由主Agent串行修改，子Agent未写入或构建。

## 原生观察子集

隔离Preview17中，中文浅色工作流审阅列出禁用计划引用并禁用移除；取消／Esc正常。另建合成工作流后重新审阅、无引用移除成功，原字段保留；再次保存旧稿显示“已被移除或更改”，没有复活定义。

英文深色MCP审阅列出准确Agent引用并禁用移除；在Agent编辑页解除来源引用并保存为version2后，来源重新审阅及移除成功。列表不再显示来源，旧MCP稿名称／端点保留；再次保存明确拒绝。审阅页截图与AX均已观察，没有发现本次范围的截断；未将截图保存为仓库资产，也不扩为全应用视觉资格。

仅读取本次自有合成Preview配置元数据核对：新工作流／MCP来源均不存在，原合成工作流保留，Agent version2的allowedMCPServerIDs和allowedMCPToolNames准确为空；语言和外观恢复system。首次元数据检查误用agentProfiles键导致断言失败，改用真实agents及准确MCP工具字段后验证通过，未将该检查错误归为产品缺陷。私有摘要在`.local/desktop/source-removal-native-metadata.json`。

全程未连接创建的example.com占位端点，未运行Agent、真实AI或命令，没有填入密钥、授权TCC或读取正式配置／个人正文。

## 待完成范围

本增量干净源本机／同源CI与可分发流程已完成，具体资格见发行证据。原全产品目标仍PARTIAL，费率快照、完整RunStore显式恢复、多模态附件、ACP与真实视觉／系统／长期验收继续保留。
