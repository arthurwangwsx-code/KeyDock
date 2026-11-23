# GitHub托管与公开发行

2026-11-23用户新增要求：整个KeyDock应用开源、Release本地打包上传，并将调试、本地安装替换和打包串成工程流水线。GitHub connector与本机gh均已核对账号arthurwangwsx-code；目标根据已选项目名和本人账号为 `https://github.com/arthurwangwsx-code/KeyDock`。同名仓库先只读核对，不覆盖或重命名其他仓库。

## 公开范围

- 原创App／Packages／工具／测试、产品技术文档、iSpec、流水线、MIT和参考链接登记。
- 同仓预发行ZIP／DMG、源commit与精确tag、实际签名公证事实和SHA256清单。
- .local、构建中间物、安装回执与备份、个人配置／剪贴板／会话、API凭据／私钥和旧AiBox／Ashot私有源码不进入仓库或资产。
- 本轮不发布网站、付费服务或第三方源码镜像。支持／反馈／隐私联系arthur.wang.wsx@gmail.com；邮箱不声明法律发布者身份。

## 分支与发行

master为唯一长期基线，开发在命名分支串行集成。编译／测试／审查通过后受控fast-forward，保留历史与命名分支；alpha公开与完整P1日用资格分别记录。远端默认分支回查为master。GitHub连接器不提供建仓／Release上传，使用已登录官方gh执行并回查。

先本地完成Developer ID、runtime、App／DMG公证装订、Gatekeeper与最终摘要。推送准确源提交与tag后上传draft，回下载、解包和实际签名／摘要一致后才公开prerelease，不提升stable/latest、不移动tag、不clobber不同资产。相同draft只补缺失文件；公开后再次核验。入口与失败恢复见[流水线设计](../technical/release-pipeline.md)。

源码公开、CI运行、打包、签名公证、安装、上传draft、公开Release与产品验收分别记录在[状态总账](../status.md)。当前执行结果完成后回填；规划文件不充当已发布证据。

MIT覆盖原创内容；参考项目为链接登记，当前无vendor源码，不为链接虚构二进制Third-Party Notices。今后迁入代码／依赖须重新做provenance与license审查。
