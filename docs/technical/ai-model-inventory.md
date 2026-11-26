# 当前服务模型清单

承接任务37.4；alpha.21的内置推荐目录及真实模型子集见[发行证据](../implementation/alpha21-release-2026-11-26.md)。本切片新增显式刷新，最终二进制／真实清单与发行分别验收。

依据[官方Models接口](https://developers.openai.com/api/reference/resources/models/methods/list)，GET清单不是能力或推荐证明。版本化官方推荐保持独立；未知ID不自动解锁思考／工具，不自动改变全局、场景或定义。当前选择即使未返回仍保留；ID使用UTF-8准确身份，NFC／NFD不合并。

仅明确点击后刷新。保存端点及localhost选项、草稿key、窗口／pane、请求UUID和凭据epoch绑定；改端点清草稿key。准确相同保存槽位才可读原Keychain，其他草稿服务可使用其明确输入的key或无key请求，不借旧服务凭据。Preview不读钥匙串，DesktopReview拒绝。模型为空也可刷新。

只有无query／fragment／userinfo、明确以`/chat/completions`或`/responses`结尾的端点可派生同来源`/models`，保留代理前缀；否则保留手工ID。不跟随重定向、分页或服务端链接；仅接收JSON基础ID，has_more显示部分清单。15秒总限、1MiB正文、512条、每ID256B，超限整体失败；服务错误正文不进入提示。复用无cookie／cache的有界HTTP transport，尾块丢弃也明确失败。

每Store最多一个实际worker，使用ConfigurationOperation随App取消／等待；4MiB工作预留计入32MiB会话预算，不为刷新逐出历史，实际drain后释放。每设置窗口只留一份最多128KiB原始ID文本的易失清单；保存服务的成功清单才可给动作／Agent选择器复用，草稿连接不污染它。变更连接或凭据使清单失效；取消／关闭／离开pane撤销发布资格，drain前禁止新请求。A→B→A及删key／换key／保存失败补偿都不能发布旧结果。相同服务刷新失败保留上次成功清单及时间，明确失败；不写配置或AI账本，不增加token调用。

定向`ai-inventory-core-v2`通过24项声明测试，含参数化情况：准确Unicode、无key／新端点、取消／ABA／关闭／删key／shutdown实际drain、预算拒绝、零自动联网、配置及选择不变；真实loopback清单／空清单／302零跳转及64槽饱和非法尾块。只读评审发现的草稿key跨端点和尾块静默丢弃已修补，旧测量保留。最终共享选择器接线、完整本机／CI和原生真实刷新另记。

首个干净源`d425092`的完整本机1000 Swift／142 Python／989 key、生产OCR及签名构建通过；[CI45756214368](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45756214368)失败于旧Responses取消测试在consumer结束后、实际worker屏障之前读取drain状态。原生AsyncStream消费者取消可以先结束，宿主实际先等待recorder.closeAndSnapshot再释放任务预算。测试现按同一屏障等待，再保留原drain／零Broker／cancelled用量与无opaque断言，不放宽时限或修改生产规则。该FAIL保留，公证未启动；修补后的完整同源资格另记。
