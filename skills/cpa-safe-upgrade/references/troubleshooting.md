# 故障排查

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

## 报告 pending transaction

不要删除 journal 或手工覆盖 runtime。针对同一 root 显式运行 `cpa-stack.ps1 recover -Json`，让恢复流程验证 instanceId、路径、exe/`data.key` hash、Manager 数据水位与服务状态。若验证失败，保留 journal 和结构化错误，再处理明确的路径、进程或数据问题；`upgrade` 不会隐式恢复。

## 无法证明版本单调

这表示旧 binary 没有可靠的 stable version。默认阻断是为了避免把 nightly/预发布版降到 latest stable。只有用户理解并明确接受后，才添加 `-AllowUnknownVersionReplacement`。

## 候选验证失败

正式服务应保持不变。只查看结构化错误和 managed root 中的小型 state 结果；GitHub Issue 中不要上传数据库、key、auth、完整配置或日志。

候选即使未成功监听，也应由 updater 按已启动的固定 `Process` 清理。不要因候选端口已经消失就假定进程已退出，也不要使用递归结束进程的命令；让事务等待原进程和 executable 文件锁释放。

如果网络必须经过代理，不要把账号口令写进 `HTTP_PROXY`/`HTTPS_PROXY` URL；安全进程环境会丢弃带 userinfo、query 或 fragment 的代理值。改用 Windows/企业无内嵌口令代理配置后重试。

## 正式切换发生回滚

用 `status` 确认 stack config 中的正式端口、健康状态和 last-known-good。自动回滚成功属于受控升级失败，不等于数据丢失。只报告版本、exe hash、检查项和脱敏错误。

## 升级已经完成但命令长时间不返回

不要并发启动第二个升级，也不要使用递归结束进程的命令。先确认配置中的正式端口仍由记录的 executable 占用，再检查 operation lock、pending journal 和结构化状态。只有在无 pending、操作锁已释放且正式服务仍健康时，才可单独结束无工作的外层 `cpa-stack.ps1` 进程；不得连带结束正式 CPA 或 Manager。

## 双击快捷方式仍弹出 PowerShell 窗口

这通常表示仍在使用 legacy 快捷方式，或托管快捷方式发生 drift。不要手工修改目标字符串；先执行 `shortcut -Action Check -ShortcutPath <path> -Json`，确认用户授权后再执行 `shortcut -Action Ensure`。接管可识别的旧快捷方式还需要显式 `-AdoptExisting`。直接 CLI 应保留当前终端，不要用可见的 `Start-Process powershell.exe` 包装它。
