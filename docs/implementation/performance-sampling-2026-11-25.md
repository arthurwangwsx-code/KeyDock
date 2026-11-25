# 性能采样与查询缓存复查

2026-11-25。本轮增加统一Release查询入口、独立合成CI和明确App／PID的本地资源采样，修补实际测到的查询超标。完整产品、屏幕首帧、8小时驻留、真实采集能耗仍未验收；下列先导测量使用dirty候选，不能当干净发行源资格。

## 原始失败与优化

固定2,000项、10预热、100正式样本，原排序p95为47.369875ms，查询链路p95为51.669292ms，未达到原50ms预算。未重试择优；先保留失败，再将Unicode规范化结果准备到命令值对象。缓存排除在编码／相等／哈希之外，初始化、旧JSON解码和文本／数组修改均更新缓存；别名、收藏、最近项和重复ID权威保持原规则。

修改后同一数据、样本与预算复测：排序p95为10.146292ms，查询p95为9.522375ms。合成目录构建与准备13.911125ms，规范化文本逻辑84,890 UTF8字节单列，不声称实际内存、索引、窗口唤起或首帧收益。

| 记录 | 本地原始目录／回执 | 结果 |
|---|---|---|
| 原查询失败 | `.local/pipeline/20261125T094836552477Z/performance/`；`performance-query-pipeline-v1.json` | FAIL，保留全部样本 |
| 缓存修改后查询 | `.local/pipeline/20261125T095637707735Z/performance/`；`performance-query-pipeline-v2.json` | PASS，测量d2ae1d40 |
| 真实Preview资源短探针 | `.local/pipeline/20261125T100055380235Z/performance/`；`performance-resident-probe-v1.json` | 完成3点／2.013秒；不是30分钟基线 |
| 自有原生生命周期 | `.local/pipeline/20261125T100535688978Z/performance/`；`performance-owned-probe-check-v1.json` | PASS，测量33e40728；正常采样、错路径拒绝、退出后失败 |
| Python边界 | `.local/desktop/performance-python-v3.log`；`performance-python-v3.json` | 16项PASS，含真实owned SIGINT／回收 |
| 查询／目录定向Swift | `.local/desktop/performance-search-targeted-v1.log`；`performance-search-targeted-v1.json` | 36项PASS，测量c8bbaeff，原100ms目录断言保留 |

回执相对路径均位于`ispec/changes/keydock-foundation/receipts/`；原始失败／超时输出保留在忽略的本地证据目录。先导机器为M1 Pro／macOS27.2 (26B123)／Xcode27.2，低电量关闭、查询thermal nominal；主机负载逐次记录，不人为删点。

## 边界与复核

独立只读评审确认值缓存的编码、修改、并发与排序兼容；资源复核另发现并修复阶段往返误归闲置、查询超时丢部分输出及Ctrl-C未留总结。原生进程CPU值按Mach ticks先取差再换算。本机125/3 timebase的忙循环对照POSIX CPU，真实短探针的比例0.999886；不把原始值直接当纳秒。

短探针绑定的Preview源与采样工具源不同，旧Preview配置未保留，因此准确标为`not-retained`。后续优化Preview必须由BuildInfo明确记录ReleasePreview，不能靠profile猜测。CPU／RSS／physical footprint尚无产品阈值；已完成采样不等于能耗PASS。

30分钟三阶段基线、干净源与同源CI、优化Preview、发行与完整本机检查需随后补证。8小时含睡眠／唤醒、真实启用采集、150ms实际屏幕唤起与完整视觉／辅助功能义务保持开放。
