# 冻结发行候选与公证恢复

2026-11-26补充：alpha.20源`aa0edfc`已通过本协议完成新的App／DMG真实提交、Accepted证明／装订、公开回下载和正式安装，任务34.4已闭合。候选、公证ID、输入及最终资产摘要见[发行证据](../implementation/alpha20-release-2026-11-26.md)。这项实际成功不反向改写alpha.19原恢复过程；unknown不重投、源／资格／同源CI等门禁保持。

任务34修补alpha.19暴露的镜像占用和等待失去可观测性，不改变签名／公证／本机资格／指定同源CI或公开回下载门禁。单一入口仍是`scripts/keydock.py`。

## 正常流程与断点

`package`将正式App复制进私有持久候选，确认复制身份；原build App不被装订修改。候选和原始响应留在`.local/pipeline/<run>/package`，索引与单写锁在`.local/release-delivery`，不放在可再生成build缓存。两处均属于协议状态；pending／unknown候选及被引用失败输出不能随“最新两份构建”清理。索引缺失时默认入口只发现并拒绝已有候选，显式路径在当前干净源／版本／build／team／本机资格／同源CI和App身份复核后才可重建索引，不认领最新目录。

App ZIP、creator原件、签名DMG输入和装订最终资产分别留存。creator只普通复制到独立inode，复制前原件／副本／复制后原件摘要一致后对副本进行image verify、签名与严格验签；签名输入冻结为只读文件，保留提交SHA。Accepted后再复制到最终资产装订，最终资产SHA单独计算。无任何系统helper终止或force detach入口。

提交先将`submission-unknown`与准确输入、源、角色、team、资格摘要和CI ID持久写入；调用no-wait submit，ID一旦获得先落盘，再wait。stdout JSON和stderr分开；submit墙钟120秒，wait墙钟1260秒且工具自身轮询20分钟，info／log各60秒。超时或INT／TERM／HUP只收口本次自建进程，不声称撤回远端效果。创建进程期间先记录取消意图，取得准确process后再收口；不结束系统helper。

同候选重试复用已确认输入和同一ID。Accepted必须由Apple日志jobID／Accepted／准确SHA验证；文件名仅审计。回执schema、绑定或输入改变时拒绝。无ID unknown不会自动重投；异常退出若stdout已完整返回ID，仍先保存该ID再报告失败。Accepted之后的装订失败保留旧输出，从不可变输入重建资产，不重新生成／签名／提交。

## 操作入口

先回到原候选对应的干净提交、原version/build和本机资格；不能从后续不同HEAD继续旧版打包。

```sh
export KEYDOCK_NOTARY_PROFILE='<已有钥匙串profile>'
python3 scripts/keydock.py package
python3 scripts/keydock.py package --resume-work .local/pipeline/<run>/package
python3 scripts/keydock.py notary-status --receipt .local/pipeline/<run>/package/inputs/notary-dmg.json
```

如果完整提交响应中没拿到ID，先人工查服务历史，保留不确定性。只对已确认候选输入的服务ID执行显式附加；没有可核验的ID就保持停止，不能删除回执绕过。

```sh
python3 scripts/keydock.py notary-status \
  --receipt .local/pipeline/<run>/package/inputs/notary-dmg.json \
  --submission-id '<服务返回的UUID>'
```

此命令不调用submit；候选路径、固定role文件名、schema、输入和当前资格均先复查，Apple完整日志SHA匹配才绑定。仍In Progress或日志缺失时不绑定未知ID。已绑定候选再运行package会继续原请求及后续本地阶段。未确认输出不会被当作成功：尚无对应公证请求的未冻结输入可以隔离保留后重建；一旦存在unknown／ID／Accepted请求，输入不再重建。分发ZIP和可由Accepted不可变输入重建的最终DMG可保留失败副本后重建。

## 资格与边界

回执读使用owned普通文件、O_NOFOLLOW／O_NONBLOCK、实际FD身份和1MiB预算；目录逐层openat无symlink并拒绝dotdot。私有目录0700、输入0400和单写锁约束正常协作。这不是抵御同UID恶意进程的沙箱：外部notarytool按路径打开输入，不能声称原子绑定其内部读取；前后摘要及Apple SHA用于发现变化，不能撤回已经发生的错误上传。

新目录同步上级目录入口；输入及回执分别同步文件和所在目录；最终资产rename后同步源／目标父目录。信号／故障回归验证调用与拒绝顺序，尚未进行实际断电试验，不作存储硬件故障保证。stage的签名／装订与验证子进程也受有界收口；hdiutil仅收口自有client，不能借进程组操作系统helper。

定向回归覆盖准确复制、漂移／链接／预算／未来schema、unknown与ID落盘故障、等待超时、并发、信号创建窗口与自有真实子进程收口、索引缺失恢复和Accepted后装订失败。历史alpha.19 Accepted输入另经新模块完成真实新inode复制、hdiutil／签名验证、Apple info／log查询与缓存零网络探针；没有新submit。该探针不等于新协议完整App／DMG发行资格，任务34.4保持开放。alpha.19已公开并安装的历史事实见[发行证据](../implementation/alpha19-release-2026-11-26.md)。

本轮28项定向通过，最终完整Python为122项通过。首次完整121项中1项旧timeout Mock未提供poll状态而失败，显式补齐该fixture的running状态后通过；另补部分image目录的完成回执与恢复，原timeout=124与SIGTERM断言保留。真实子进程取消和输出恢复单独覆盖，未把模拟进程替身当作真实公证提交。各次失败和成功测量均保留。

首个分支CI `45691090355`（源f67d646）失败日志artifact `15059196291`已回下载，SHA256 `bf20065b33ef321313f108584290c024eb252ba5b67c9bb0d39de6b20ec1ed2f`。它暴露旧timeout fixture的`/var`别名，以及云端Python 3.15中原InterruptedError取消表现为等待超时的差异；夹具显式resolve并用owned别名全套复查，取消改用独立应用异常避免OS重试语义，保留真实子进程和超时断言。本机Python 3.9／3.14各122项别名路径检查通过；3.15复核由新源CI记录，不固定到旧Python规避问题。该失败不能当作后来修补源的CI资格。

最终源`d2c9a01cad6c237f163d423a41897f67284488d9`的[同源CI45691921390](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45691921390)及优化Preview构建通过，日志artifact `15059857372`完整回下载并核对21文件／10个零退出阶段及全部日志摘要，archive SHA256 `dde0d29961c34345356b24aa96899ebcece36f6a1f3790b15787b3456da9fc70`。Python 3.15上的取消回归也通过；云端OCR仍NOT_QUALIFIED。已受控fast-forward晋升master；alpha.19 tag和安装App仍固定原e488496，新协议真实发行保持34.4开放。
