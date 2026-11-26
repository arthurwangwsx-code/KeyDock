# 用量清除晚快照修补

本增量承接42和费用预算前置；alpha.27已公开发行并替换正式安装，完整产品仍PARTIAL。二进制／tag固定代码源`e6c7b98aa3dfd563f957cdb7f6ef6048386a23fc`；后续交付文档提交不冒充二进制来源。

基线在fe27e3e上的确定性RED：Core将已结束预算回执清成nil／0，但同history代次的旧快照重新恢复31token／2轮。measure d3dfb84e-22b6-4f1c-b064-0f1f5ee3aa45失败2项，receipt摘要b92d8e644a1235bd02d4fbcf2da91f8c7e67aae055d973a8c75325d1710781ac保留；没有外部API或个人数据。

新增进程内usage读取票据，启动读取与失败历史组均在两库读取前捕获；无票据只剥离数字，图身份保留。AI／workflow的ledger读取同步补上清除中捕获的围栏。46项定向／5套件通过，measure b8bebc25-c83e-476e-9e8f-ce21a97f3535，receipt摘要2b45604424b03184cb221b8d7828d0a6480bcd5702702563b7318b5d9151b792。

其中真实失败组测试使用owned CLI写入门控：缓存旧AI快照后完成用量清除，再让AI历史删除恰好EIO一次。恢复任务仍为completed、budget未知、阈值100及runAttempt不变，AI文件保持清除后的准确字节，CLI组实际删除；显式等待清理Task退出，不用异步defer删除测试目录。

尚未实现：42.4的TTL／数量／字节维护对预算副本的完整清理。不能将手动清除围栏称为已覆盖全部自动维护。5.4费用停止阈值仍为方案，未进入本次代码。原生和真实服务资格不会从alpha.26自动沿用。

## 精确源资格

干净源完整本机通过：1080 Swift执行／1059声明（1049 core、9 Terminal、1 OCR）、156 Python、1035中英key，生产合成OCR两轮。检查summary文件摘要`0ed5491f0e01e664ef238a13c9b5067c4719325a0bac4dc344c80ecd61cb39d0`，qualification规范摘要`f7b438eea8a0b5645c4c8a895b11b9e5e1d5a2b6f2e33565e439e0e99e3ea3ec`。measure `1428951e-4a7e-4f91-ae64-c4cbc1a7ddc3`，receipt摘要`d97e672b2bf0eac5aa26ba6a0cb48d6feaf860536624fdfc3fd79ed97187c0f7`。同源[CI45816057630](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45816057630)及优化Preview通过；静态Agent复核未发现当前范围阻断。

独立owned合成根`049c8559-7a55-4571-87af-46297e63ae40`先通过Core真实清除一个已结束31token／2轮预算，再创建清除后的新回执；没有配置API或凭据。原生中文深色旧任务显示100阈值／消耗未知，新任务显示31／剩余69；切英文浅色保留旧任务选择，状态及说明完整。实际正常退出0、两个ID和图不变、无新attempt。原生measure `7dcd43e6-24b3-4b3e-811b-666251c8c4cb`，后置条件`0e8347cb-7edc-4436-bb04-20a11ead77f9`；postcondition文件摘要`1e9934be91c56c93ccdb9551d518729985ee0b1b0d6e7fcf1c22709ee09471fe`。

这些截图仅验证预算卡。合成新回执未配ledger，所以其卡31／69和下方用量摘要未知可以同时存在；不补算完整摘要一致性。独立视觉Agent逐张检查三图，未见本范围阻断或明显裁切，浅色辅助说明对比度仍需实测；AX树不替代VoiceOver。首个打开工作区后的AX观察曾返回failure，下一次观察确认工作区已打开，未重复触发。GUI清除按钮、真实GUI启动竞态、完整玻璃／系统矩阵、实体热键及真实插入不据此记PASS。

## 发行与安装

App公证`3782bff7-61dd-4400-9e87-1da182f9c420`及DMG公证`11bd0d91-c663-4c49-a4ca-44b1ae790293`均Accepted，装订及Gatekeeper通过。ZIP 3750781字节、摘要`cba0b5f6630d9b9d41568b05ad96c67c6c4f8a84ae94cad75dcb749dc1140604`；DMG 4277630字节、摘要`8f66977ed48a702bbc3e236582ee054d4392e49911531477b0ebb25506557c8c`。本地打包measure `9382ce7f-fac0-4bd6-baa7-0e895268c58b`，receipt摘要`ab502fe8e469be4f78c48ad7a9fbeb298db4e9a7463d62da8ad1be13fbda6058`。

[alpha.27](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.27)经draft回下载验签／验哈希后公开，publish measure `9c176d04-e8b4-43d2-b481-bf8d088c6cb7`、receipt摘要`8b53dbb142181db329e9af0bb56b56676e0439bd3803732d7422e1f5b48278d2`；独立[发行资产审计45818353644](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45818353644)通过。

正式安装事务`84cc0827-2223-4c10-9b9f-5b25396b3b7c`原子替换`/Applications/KeyDock.app`、保留alpha.26回退，install measure `33554596-fa0e-45b3-9534-4587b642095f`。正式About实际显示`0.1.0-alpha.27 (27)`；设置页保留全局Sol low／自动协议→Responses／4096、翻译Luna none／继承4096与密钥已保存空字段，没有保存配置或发起新模型生成。没有导出凭据。

最新两份完整raw保留alpha.26／27；alpha.25 raw先压缩、恢复核对整树及签名后移除。引用的alpha.22失败、所有回退包与metadata保留，未清理其他项目；存储验收不替代产品验收。
