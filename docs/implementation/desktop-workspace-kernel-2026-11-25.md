# 桌面工作区执行内核复查

2026-11-25，canonical KeyDock的`fix/ui-semantics-and-text-sync`继续实现任务20.3。root独占写入／验证／Git，两名子Agent只读审查。**本增量完成冻结窗口布局和精确焦点交接内核，完整工作区执行仍PARTIAL**；界面仍只提供定义管理，没有开放profile执行或执行快捷键。正式安装／发行保持alpha.7，OCR门禁未放宽。

## 实现

- `WindowLayoutController.prepare/revalidate/applyPrepared`冻结原AX对象、原／目标frame及屏幕快照；prepared一次claim，失败后新lease也不能重放。全部AX访问继续在后台有界worker，主线程处理UI和拓扑／焦点事件。
- `prepareWorkspaceWindows`在一个拓扑快照上准备全部1–8个窗口并统一复核，第二项失败不布局第一项。重复进程／对象、不可写窗口、失效屏幕和缺失调用屏幕明确拒绝；不偷偷重新选窗或重算旧计划。
- 显示通知递增拓扑代次，worker的每个布局请求检查代次／lease／进程／权限；取消等待真实worker，不以任务flag代替drain。主屏幕是screens首项，调用屏幕须由组合根明确提供。
- Restore引用使用PID／启动时间＋CFEqual驻留的UUID，与旧哈希字符串脱离。冻结的Restore另绑定基线nonce。frame-specific witness在首次AX请求前标记；零frame提交的失败撤回自身候选，部分写保留已有恢复入口。
- `DesktopWorkspaceFocusFence`只批准精确源→当前目标，目标出现后旧源失效；第三方事件／未知身份使其永久撤销。`DesktopOperationGroup`封闭注册并撤销全部fresh child，计数等待宿主真实收口后才释放。
- `WorkspaceWindowFocusController`先完成只读验证、核对holding源，再在同一主线程片段arm／activate；原对象raise／focused setter后总是CFEqual读回。原单窗口`DesktopApplicationFocus`授权范围保持不变。
- `DesktopWorkspaceFocusSession`覆盖整个批次，close／析构都会撤销。预取消进入取消处理器，迟到readback不能成功；最终CFEqual之后直接同步完成，不再插入异步membership等待。

## 发现与修补

只读审查发现：旧布局在AX写入前就保存Restore基线，若随后零写入失败会残留错误原位置。本轮以frame witness修补，测试区分“同lease曾激活”与“实际frame已提交”。随后审查补齐了CFHash碰撞导致基线相互覆盖、旧Restore消费新基线、预检等待时提前许可目标、session释放后失去观察器、最终读回后额外等待及入口预取消六处边界。

没有执行真实桌面布局／应用激活、读个人窗口或修改系统权限。测试只构造不发送消息的AX对象，并注入合成进程／屏幕／worker端口。相同进程不同对象的Restore隔离由合成回归覆盖；没有声称造出了真实CFHash碰撞或做过物理断屏。

## 验证记录

| 测量 | 结果 | 范围 |
|---|---|---|
| `051c0c85-faec-4e0e-94e5-4a0e2c097811` | PASS | 首轮11 tests／1 suite，48.722s；冻结、Restore、屏幕／身份变化和真实worker gate drain |
| `e0a351c8-fa34-4644-aebb-43501f63729c` | PASS | 37 tests／5 suites，41.214s；新增focus／group和旧应用／激活回归 |
| `40e0e02f-2fdf-4588-8c2d-54d27f8a045b` | PASS | 41 tests／5 suites，15.459s；统一复核、单plan竞争、写中拓扑变化、holding围栏 |
| `c2f0432a-14b2-4fca-883c-813604c2a12a` | PASS | 43 tests／5 suites，9.552s；最终读回无额外等待、预取消 |

计数采用Swift Testing的test-run结果，参数化case另在日志列出，不能把每条日志都算成独立声明。前几轮测试存在未使用返回值编译警告，随后显式丢弃；没有弱化断言或删除失败日志。开发中一次apply_patch因同补丁重复文件操作在校验阶段拒绝，随后顺序修正，没有编译缺文件状态。

## 尚未完成

应用全量目录／唯一实例预检、有界后台启动及已提交unknown事实、父子durable receipt、总任务槽位、定义修改／新入口撤销与等待、profile catalog／快捷键跨档案生命周期和执行UI尚需整合。当前这些部分不能以本次内核绿测视作完成。

实际AX授权／撤销、多应用窗口／Spaces／多屏／物理快捷键、完整中英深浅视觉与最低系统验收仍未完成。当前内核检查与云端系统OCR为不同范围，未重新声称OCR通过或放行alpha.8。完整产品状态见[总账](../status.md)。
