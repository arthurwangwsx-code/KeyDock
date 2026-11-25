# AI输入编辑与提交复查

2026-11-25。alpha.10开发候选；公开／已安装版本仍为alpha.9，完整产品PARTIAL。

先用合成loopback复现：NFC／NFD字符串在Swift中相等但字节不同，原编辑没有更新正文或revision，迟到命令建议仍进入审阅。原3项测试5个issue保留在`.local/desktop/ai-input-byte-edit-reproduction.log`，measurement `2d97ddb2-3c4d-4f37-b34b-a1f8dfd80c14`。修补后准确保留UTF8字节，旧任务仍保留真实完成状态，但不能覆盖当前草稿提示或进入当前建议队列。

KeyDockUI提供共用输入提交检查，运行菜单、AI／Agent／工作流用户提交和编辑器保存遵循当前编辑器marked-text状态。组字状态不进入配置准备缓存，结束组字不需要另改配置；冻结后的后台工作流仍可以运行。保存命令与AI动作列表的编辑／运行动作补充具体对象的辅助名称。

46 tests／5 suites定向PASS，含owned NSTextView组字、真实合成HTTP零请求与恢复后请求、冻结工作流运行、Unicode迟到建议和原窗口／配置回归。measurement `f2267ec2-a31e-434a-a3cf-bfa5f99716c5`，日志`.local/desktop/ai-input-byte-and-marked-text.log`，receipt SHA256 `20d5aea9c5a14607a944f249dc391471733466622e38b4a780d0c0247bb78d3d`。

这是代码与合成服务验收，不是实际中文输入法、VoiceOver、物理全局快捷键或完整视觉矩阵PASS。常规App隐私页本轮仍显示需要辅助功能授权；未修改TCC或配置真实API。
