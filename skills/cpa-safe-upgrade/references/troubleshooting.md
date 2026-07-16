# 故障排查

## 目标盘不存在

CLI 返回 `TargetDriveNotFound` 时，选择真实存在的本地 NTFS/ReFS 盘，或先挂载目标盘。示例 `E:` 不能假定每台电脑都有。

## Root 被拒绝

使用专用目录，例如 `E:\CPA-Stack`。不要使用盘符根、UNC、Git worktree、Windows/Program Files 子树或用户主目录本身。LocalAppData 下的专用子目录允许使用。

## 找不到旧安装

先让旧 CPA 与 Manager Plus 正常运行，使 8317/18317 暴露 executable path。若仍不能唯一获得 config、data 与 key，显式传 `Source*` 参数和受保护的 `SecretsInputPath`。

## 候选端口被占用

不要自动终止未知进程。先识别 8318/18318 的 owner，适当处理后再重试。

## 缺少 Python

安装 Python 3.10+，并确保 `python` 或 `py -3` 可用。无法创建一致 SQLite 快照时，工具会在正式停机前退出。

## 更新 Skill 时目录被占用

关闭正在查看已安装 `SKILL.md` 的编辑器，或工作目录位于该 Skill 下的终端，然后重新运行新版 `install.ps1`。安装器只会有限重试，不会结束用户进程；失败时必须保留当前 Skill、已有 `previous` 和未接管的 legacy 状态。若结果是 `success=true`、`complete=false`，新 Skill 已提交；根据 `postCommitWarnings` 解除 launcher、root locator 或 retained slot 的占用/ACL 问题后重试，不要手工混合复制版本。

## 报告 pending transaction

不要删除 journal 或手工覆盖 runtime。针对同一 root 再运行 `cpa-stack.ps1 upgrade -Json`，让恢复流程验证 instanceId、路径、hash、服务与 Manager baseline。

## 无法证明版本单调

这表示旧 binary 没有可靠的 stable version。默认阻断是为了避免把 nightly/预发布版降到 latest stable。只有用户理解并明确接受后，才添加 `-AllowUnknownVersionReplacement`。

## 候选验证失败

正式服务应保持不变。只查看结构化错误和 managed root 中的小型 state 结果；GitHub Issue 中不要上传数据库、key、auth、完整配置或日志。

如果网络必须经过代理，不要把账号口令写进 `HTTP_PROXY`/`HTTPS_PROXY` URL；安全进程环境会丢弃带 userinfo、query 或 fragment 的代理值。改用 Windows/企业无内嵌口令代理配置后重试。

## 正式切换发生回滚

确认 8317/18317 健康状态和 last-known-good 路径。自动回滚成功属于受控升级失败，不等于数据丢失。只报告版本、exe hash、检查项和脱敏错误。
