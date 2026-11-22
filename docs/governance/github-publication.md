# GitHub 托管与公开范围

2026-11-22 已通过 GitHub connector 确认当前用户为 arthurwangwsx-code，并核对本机 gh 身份一致；未创建仓库或推送。原有公开仓库不重命名、不改默认分支、不自动迁移。

## 具体候选

- 目标：`https://github.com/arthurwangwsx-code/KeyDock`，新建 public repository，默认分支 master。
- 内容：本仓库原创产品/技术文档、iSpec change、参考链接与 revision、MIT、开发规则和文档校验脚本。
- 排除：.local、机器生成 skills、AiBox/Ashot 源码、凭据/配置、个人媒体/剪贴板/会话、build 与安装包。
- 发布形态：源代码/方案托管；本轮不发布网站、App Release、付费服务或第三方源码镜像。

用户已允许开源托管方向；根据用户“不得自动发布/推送未批准远端”的规则，完成本地审阅版后确认上述具体目标再创建与 push。GitHub connector 当前没有建仓能力；确认后可用已登录的官方 gh 分步完成，记录各步结果并用 connector/read-only API 回查；失败时保留现状，不自动删除远端。

## 准备与后续动作

1. 文档链接、参考 revision/license、iSpec artifacts 与只读评审通过；本地命名分支提交并受控 fast-forward master。
2. 展示仓库名、public 范围、提交和排除项，获得针对具体目标的确认。
3. 先检查目标不存在；如同名已存在则只读核对归属/内容，不覆盖、不改默认分支。
4. 用 gh 创建空 public 仓库并设置 origin；push master 与命名分支，回查默认分支/可见性/commit。
5. 手动确认远端 master 稳定后再配置保护规则与 CI；PR/Issue 拆分按用户后续选择执行，不在本轮批量发通知。

GitHub Actions 的文档检查文件可随源码提交，不自动部署。未来 PR 目标 master；禁止 force push、worktree 和从其他 feature 分支起步。保留 feature/product-foundation 作为可追溯规划分支。

MIT 仅覆盖原创文件；参考项目不是本仓库依赖。发行前重新核验来源、许可证与实际 source package，生成 Third-Party Notices。版权署名 KeyDock contributors 不声明实际法律发布者身份；公开支持/隐私联系统一 arthur.wang.wsx@gmail.com。
