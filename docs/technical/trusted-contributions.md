# 受信版本化贡献目录

2026-11-25，任务25已完成实现、45项定向回归和原生配置子集，已随alpha.11发行并安装。完整产品验收仍PARTIAL；公开与安装证据以各版本记录为准。

## 用户行为

设置增加内置工具开关：计算／单位换算、命令行工具、文件搜索。关闭后不产生新的结果或运行，保留输入、保存定义、目录、收藏、别名和快捷键偏好；有效系统快捷键随同一事务停止注册。重新启用重查冲突，失败恢复原配置与注册，不发布候选目录。已开始的CLI／工作流／Agent使用当时冻结的版本、参数及工具范围继续执行，仍遵守真实资源权限和原审批；暂停／停止继续走既有任务入口。面板明确说明这些在途行为。

## 目录与执行合同

CommandCore保存纯`ContributionManifest`、版本化provider引用、已编译handler合同、解析引用和不可变snapshot。声明包含既有CommandDescriptor／ActionDescriptor，精确匹配toolID／toolVersion、输入输出、context和effects；缺失、重复、错版或伪造效果拒绝，不回退最新版。Workbench组合根只注册随App编译的provider和handler，不读取外部JSON注册代码，不宣称外部插件沙箱或ACP支持。

Workbench的runtime按provider／handler版本化ID查表。provider生产的CommandItem携带贡献／动作引用、启用代次及必要的输入revision。handler消费宿主冻结的类型化输入；类型擦除只发生于受信组合根，外部文本／payload不能指定函数。执行使用解析出的同一描述进入HostDescriptorPolicy，不根据kind重建另一份效果声明，也不在handler外重复admission。

新增贡献只需注册provider、handler与独立surface；不再增加WorkbenchModel.execute中的能力分支。保留既有命令ID和偏好身份。迁移命名空间中的缺失或过期绑定拒绝，不能回退旧switch或只凭payload运行。

## 三个实际迁移

- 计算／单位：Launcher与Tools共用有界纯求值；复制重新验证结构化表达式与计算结果，最终一次授权、一次writer，不信任任意`calculate.`后缀。
- CLI：Launcher、设置和集合共用注册handler，接入原validate→authorize→reserve→intent→Process／Terminal→receipt→drain；不得新增第二任务库或reservation。新的Workflow／Agent保存命令快照同样检查启用状态，已有运行不重解析或扩权。
- 文件：Launcher与Tools共用注册provider与Reveal handler。查询冻结贡献版本、queryID／generation、目录和所属service；保留bookmark lease、缓存成员、objectRevision和目录身份。异步验证后复查当前查询／选择／目录／贡献代次，再授权并同步请求Finder，不将裸路径交给通用open。

## 生命周期与事务

开关走既有commitShortcutConfiguration，OS注册和配置落盘成功后才发布新snapshot／epoch。失败不变更公开状态，沿用写后抛错与注册补偿。快捷键回调在按键派发时冻结贡献引用、epoch及对象revision，等待AX捕获结束后再复核；关闭后再开启也不能复活旧按键。查询返回与点击时同样复查snapshot代次，禁用后旧结果不成为新动作。

## 验收

验证真实三类入口、错版／重复／伪造描述、一次复制／一次CLI任务与回执、begin失败零Process、乱序文件结果／目录移除／对象替换／异步Reveal期间变化零Finder、禁用再启用旧结果／热键失效、注册与写前／写后故障补偿、在途冻结及Workflow／Agent无旁路。使用合成输入和工程拥有的目录、进程、loopback；测试／构建／iSpec索引串行。原生双语设置、保存／重启与视觉子集单独观察，真实权限／API／完整矩阵不由这些测试替代。

计划授权指纹绑定已安装的贡献／action／execution版本，开关代次不进入授权指纹。升级改变CLI契约后，旧计划暂停并要求复核；禁用时保存和编辑定义仍可用。Workflow与Agent在启动时冻结工具合同，实际Request／Grant使用相同action和execution版本，模型工具名与原逐次审批不变。
