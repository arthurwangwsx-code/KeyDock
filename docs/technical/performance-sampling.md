# 性能采样与资格

此增量接通工程采样入口，不把查询耗时、应用绘制或短期RSS当作屏幕首帧、整机能耗或长期驻留资格。原预算保持热唤起p95≤150ms、缓存首批p95≤50ms；CPU／RSS／physical footprint先建基线，不临时设门槛。

## 查询

统一入口构建Release版KeyDockDiagnostics，固定2,000条合成项、预热10次、正式100次。分别保存纯排序与QueryRequest→缓存Provider→QueryCoordinator→第一个可展示ResultBatch的原始样本、最近秩分位数、最大值与完整结果校验；准确queryID／generation不符、空批次无终态、非有限耗时或样本不足均失败。每次运行保留独立目录，不重试取最好值。首批的50ms预算只应用于所声明的查询链路。

记录runner源SHA／dirty、实际工具摘要、Release配置、Swift／Xcode／OS／芯片、低电量模式及主机负载。CI可执行查询基准，但它不提供GUI／OCR／AX或150ms热唤起资格。

命令值对象在初始化、解码或文本写回时准备Unicode规范化字段，查询复用这些字段；缓存不进入编码、相等或哈希，偏好和重复ID仍按当前调用处理。诊断另报目录准备耗时与规范化文本的逻辑UTF8规模，后者不等于实际分配、RSS或冷启动预算。

```sh
make performance
# 仅启动／回收本次创建的原生探针夹具，校验CPU单位、路径拒绝和退出失败
python3 scripts/keydock.py performance --mode probe-check
# 明确使用已运行的App和PID；不会替你启动或重新选择目标
python3 scripts/keydock.py performance --mode resident \
  --app "$HOME/Applications/KeyDock Preview.app" --pid <已核对PID> \
  --duration-seconds 1800 --interval-seconds 5
```

运行中标准输入可逐行提供`{"phase":"synthetic-interaction"}`或`{"phase":"recovery-idle"}`。阶段变化的跨界区间不算稳定闲置，采样之间的往返也会保留；标记不执行动作。结果在`.local/pipeline/<独立运行>/performance/`，包括原始查询输出／JSON或资源NDJSON、CPU单位对照和摘要。只保留本地；独立CI仅上传合成查询产物。

查询原始stdout／stderr直接写文件；超时或Ctrl-C只回收本次创建的查询探针，保留已有字节和终止状态。驻留预检中断也生成`interrupted / NOT_QUALIFIED`；没有资源样本时不补零。

## 自有进程

只附着已运行的明确App／PID，不启动、停止、恢复或自动重附着。App限KeyDock常规或隔离Preview，核对bundle、BuildInfo与签名／实际资源摘要；App与runner的源码分别记录，不假定二者同源。采样前后核对进程UID、准确可执行路径、出生身份与实际Mach-O UUID；zombie或退出标记拒绝，磁盘候选UUID须与正在运行映像匹配；PID退出／复用、App文件变化、读取失败或计数回退立即停止，并保留原始样本与未完成事实，不把未知当零。

使用公开libproc接口读CPU累计Mach ticks、RSS与physical footprint，不获取task_for_pid权限，不读argv、窗口、正文、文件内容或其他进程用量。CPU原始tick先取差，再按mach_timebase_info转换；CPU差除以连续单调钟墙钟差×100%，另记录absolute／continuous差以识别睡眠区间，一个满载核心为100%，多线程可超过100%；RSS与physical footprint分别报告，32MiB文本预算不等于进程内存。

默认5秒一次，短基线至少30分钟，独立的长期样本至少8小时并包含睡眠／唤醒场景。隐藏闲置、合成操作、恢复闲置分别记录阶段；阶段标记只是记录，真实UI操作仍由用户或原生验收工具完成。原始JSON行逐条保留，正常完成／目标失效／取消均有总结；更短运行仅称工程探针验证，不升级为基线PASS。

新构建在BuildInfo记录准确配置（包括ReleasePreview）。旧App没有该字段时报告`not-retained`，不能从Preview身份推断优化配置；App源和采样器源必须分别列出。

## 尚未关闭的义务

首帧需屏幕呈现与交互trace；makeKeyAndOrderFront返回、onAppear、didUpdate、下一次主队列或绘制回调均不证明画面已经显示。当前采样入口不关闭该项。短时稳定、隔离Preview的低负载或单点低RSS也不关闭真实启用采集、功耗与长期驻留。

CPU单位依据[Apple XNU任务用量填充](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)和[任务CPU计数](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)核对，并以本机非1:1 timebase的自有忙循环／getrusage粗对照验证；不直接把raw计数标为纳秒。
