# 故障排查

## 检测到 0.x updater 残留

installer 可以原子替换发现到的 0.x Skill 安装并保留 previous，但不要继续执行或恢复 0.x journal 与事务状态。保留现有 CPA/Manager 业务数据，通过正式 `migrate` 或 `upgrade` 流程建立新的 managed root。

## 目标盘不存在

CLI 返回 `TargetDriveNotFound` 时，选择真实存在的本地 NTFS/ReFS 盘，或先挂载目标盘。示例 `E:` 不能假定每台电脑都有。

## Root 被拒绝

使用专用目录，例如 `E:\CPA-Stack`。不要使用盘符根、UNC、Git worktree、Windows/Program Files 子树或用户主目录本身。LocalAppData 下的专用子目录允许使用。

若错误指出 Windows PowerShell 5.1 路径预算，缩短 managed root 或来源树中的深层名称：目录必须不超过 247 字符，文件必须不超过 259 字符，且事务临时后缀也计入预算。该检查发生在正式停服或禁用 collector 前；不要通过手工停服绕过。

## 找不到旧安装

先让旧 CPA 与 Manager Plus 正常运行，再执行 `status`。若仍不能唯一获得 runtime、config、data 与 key，按 [migration-request.md](migration-request.md) 创建显式 request；不要假设正式端口或把 secret 值写进 request。

## 候选端口被占用

候选端口由执行器动态分配为未占用的高位 loopback 端口，不存在固定候选端口。不要终止未知进程；保留结构化错误并重试。重复失败时检查系统端口耗尽或安全软件拦截，不要绕过 loopback 门禁。

## 缺少 Python

安装 Python 3.10+，并确保 `python` 或 `py -3` 可用。无法生成并重新打开通过 `quick_check` 的 SQLite online backup 时，工具会在正式停机前退出。

## 更新 Skill 时目录被占用

关闭正在查看已安装 `SKILL.md` 的编辑器，或工作目录位于该 Skill 下的终端，然后用同一个可信本地发行目录先执行 `install.ps1 -Action Check`，明确授权后再执行 `-Action Update`。安装器不会结束用户进程；失败时保留当前 Skill、`previous` 和受保护 journal。不要手工混合复制版本，也不要从网络管道执行 installer。

## 自动更新 updater 失败

`upgrade` 返回 `automation.failedStep=updater` 时，不要绕过检查或直接调用内部 runtime 脚本。保留结构化 `error.code`：Release 查询失败时检查 GitHub HTTPS 访问；校验失败时等待官方重新发布正确的版本化 ZIP、`checksums.txt` 和 digest；installer pending 时再次运行同一个公开 `upgrade`，由下载到本地的 installer 恢复。不要改用源码分支、fork 或远程管道执行。

## 报告 pending transaction

不要删除 journal 或手工覆盖 runtime。直接针对同一 root 运行 `cpa-stack.ps1 upgrade -Json`；它会自动调用一次受限 recovery-only 流程，验证 instanceId、路径、exe/`data.key` hash、Manager 数据水位与服务状态后继续。若返回 `ManualRecoveryRequired`，保留 journal 和结构化错误并停止。

`maintenance.pending.json` 属于离线数据库维护事务；重跑 `cpa-stack.ps1 maintenance -Action CleanupDerived -Json`，它会先验证并恢复备份、重启服务，再重新维护。不要用普通 `recover`、手工删除 journal 或直接复制数据库。

## 无法证明版本单调

公开 `upgrade` 会自动允许用已验证的 latest stable 替换无法可靠识别版本或来源的旧 binary，不需要额外参数或确认。release checksum、候选健康、SQLite 水位和失败回滚仍按原安全门禁执行。

## 候选验证失败

正式服务应保持不变。只查看结构化错误和 managed root 中的小型 state 结果；GitHub Issue 中不要上传数据库、key、auth、完整配置或日志。

新版升级结果中的 `upgrade.diagnostics` 保留按时间排序的脱敏诊断，同一数组也保存在 `state/last-upgrade.json` 的 `diagnostics` 中。先找第一条包含 `failedChecks` 的健康检查，或 `kind=exception` 的记录，再对比后续恢复检查；不要用最后一次成功检查覆盖首次失败证据。`http` 可区分具体接口的 HTTP 状态码与超时/连接失败，异常记录只保留脚本文件名、行号和类型，不包含调用参数或原始响应。

`success=false` 可以同时伴随 `changed=true` 或 `recovered=true`：组件可能已切换、后续恢复也可能成功，但整个升级仍未完成。按错误停止后续运行时操作；需要诊断时使用公开只读 `status` 核对当前服务，不把这些字段当作绕过失败门禁的依据。

候选即使未成功监听，也应由 updater 按已启动的固定 `Process` 清理。不要因候选端口已经消失就假定进程已退出，也不要使用递归结束进程的命令；让事务等待原进程和 executable 文件锁释放。

如果网络必须经过代理，不要把账号口令写进 `HTTP_PROXY`/`HTTPS_PROXY` URL；安全进程环境会丢弃带 userinfo、query 或 fragment 的代理值。改用 Windows/企业无内嵌口令代理配置后重试。

## 正式切换发生回滚

用 `status` 确认 stack config 中的正式端口、健康状态和 last-known-good。自动回滚成功属于受控升级失败，不等于数据丢失。只报告版本、exe hash、检查项和脱敏错误。

Windows 安全软件或文件系统过滤器可能在回滚快照刚完成时短暂拒绝目录改名；Windows PowerShell 5.1 还会把 sharing violation 折叠为通用 I/O 错误。updater 只在源目录仍存在且目标仍不存在时做固定上限重试；路径状态发生歧义、持续拒绝或非 I/O 错误仍立即失败，不能手工移动 staging/pending 目录绕过事务。

## 升级已经完成但命令长时间不返回

不要并发启动第二个升级，也不要使用递归结束进程的命令。先确认配置中的正式端口仍由记录的 executable 占用，再检查 operation lock、pending journal 和结构化状态。只有在无 pending、操作锁已释放且正式服务仍健康时，才可单独结束无工作的外层 `cpa-stack.ps1` 进程；不得连带结束正式 CPA 或 Manager。

## 双击快捷方式仍弹出 PowerShell 窗口

这通常表示仍在使用 legacy 快捷方式，或托管快捷方式发生 drift。不要手工修改目标字符串；直接执行 `shortcut -Action Ensure -ShortcutPath <path> -Json`。可识别的旧 CPA 快捷方式会先备份再自动接管，未知无关冲突仍拒绝覆盖。直接 CLI 应保留当前终端，不要额外包装另一个 PowerShell。
