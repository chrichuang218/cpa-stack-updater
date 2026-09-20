# CLI 使用说明

安装后只使用稳定入口：

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cpaCli = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
```

仓库根目录的 `cpa-stack.ps1` 仅是开发转发器。

## 根目录解析

`-Root` 优先于 `CPA_STACK_ROOT`、受保护 root locator 和 `%LOCALAPPDATA%\CPAStack`。示例中的 `E:` 不是固定要求；目标必须是当前电脑上的专用本地 NTFS/ReFS 目录。

## v2 命令

### status

```powershell
& $cpaCli status [-Root <path>] [-Json]
```

唯一默认只读检查。返回 `requiredOperation`：

- `recover`：存在单一可恢复 pending transaction；
- `migrate`：尚未建立 canonical stack、需要迁移或需要接管旧 canonical root；
- `null`：没有可直接执行的前置事务。

栈不健康但检查成功时，`success=true`、`outcome=Blocked`、退出码 0。检查协议失败时 `success=false` 且退出非零。

### recover

```powershell
& $cpaCli recover [-Root <path>] [-Json]
```

显式恢复一个可证明的中断事务，包括初始化/升级及其从属 switch artifact、旧 canonical 接管。无 pending 时返回 `NoChange`。journal 类型歧义、instanceId/path/hash 不一致或恢复后仍中断时返回 `ManualRecoveryRequired`。恢复只调用 recovery-only interface，不会自行开始迁移或升级；`upgrade` 可把它作为一次有界前置步骤，`start` 不会。

### migrate

```powershell
& $cpaCli migrate [-Root <path>] [-RequestPath <json>] [-Json]
```

不带 request 时执行安全自动发现；来源不唯一时使用显式 request。格式见 [migration-request.md](../skills/cpa-safe-upgrade/references/migration-request.md)。

request 支持：

- `sourceMode=Auto|Explicit`
- CPA runtime/config 与 Manager runtime/data
- `secretsInputPath` 或受支持的 legacy launcher
- 两个不同的可选正式端口

request 不得包含 secret 值。候选端口由执行器动态分配，不能在 request 中指定。

### upgrade

```powershell
& $cpaCli upgrade [-Root <path>] [-RequestPath <json>] [-Json]
```

单命令自动执行 `updater → recover → migrate → runtime upgrade → shortcut Ensure`。它先检查固定官方 updater Release；发现更高稳定版本时验证版本化 ZIP、`checksums.txt` 与 GitHub SHA256 digest，原子更新 Skill，并用新版 CLI 重执行一次。然后恢复一个受支持 pending、迁移尚未建立的 canonical stack、升级 runtime 并维护默认桌面快捷方式；`-RequestPath` 可为自动迁移提供显式来源。

普通 `upgrade` 自动允许 latest stable 替换无法可靠识别版本或来源的旧 binary，不需要额外参数或确认。

已有受管实例的日常升级不预跑候选服务、不复制凭据：校验官方包后，备份、替换重启并探活，失败回滚该组件。成功只提交状态并归档，不重复整栈检查。首次迁移仍保留候选验证。旧版候选事务记录继续支持恢复，新事务使用 runtime-only 格式。

只更新 CPA 时不进入 Manager 数据库备份流程。Manager 确实更新时，停服前准备旧程序备份；停服后再一致性备份数据库及 `data.key`，保留最近一份成功归档的回滚备份。不拆表、不做增量备份、不清空历史。若旧备份清理失败，会明确给出 warning，而不是强制删除。

updater 查询、校验、安装或新版重执行失败时，返回 `automation.failedStep=updater`，不会继续使用旧 updater。除默认桌面快捷方式的自动 Ensure 外，其他快捷方式路径不会隐式修改。歧义 journal、未知端口 owner、不可信 ACL/reparse、checksum、切换后健康、磁盘/路径预算、SQLite 水位或回滚失败仍立即返回失败。

Windows 定时任务应使用 `pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <cpa-stack.ps1> upgrade -Root <root> -Json`。这同时授权自动更新 updater；退出码 `0` 表示 updater/runtime 成功或无需更新，非零表示真实失败。命令不读取 stdin、不打开浏览器、不产生确认提示。

### start

```powershell
& $cpaCli start [-Root <path>] [-NoBrowser] [-Json]
```

启动或复用已接管栈。pending transaction 会返回 `RecoveryRequired`，不会自动恢复。

### maintenance

```powershell
& $cpaCli maintenance -Action CleanupDerived [-Root <path>] [-Json]
```

处理 Manager Plus 的“数据库升级维护尚未完成”、查询索引或旧派生数据提示。事务只使用 canonical 配置中的当前 Manager 二进制和正式 `usage.sqlite`，不接受外部路径；先建立一致性 SQLite 备份，再固定并停止已验证的 Manager 进程，执行 `cleanup-derived`，校验 `quick_check`、权威请求水位、关键表、exe 与 `data.key`，最后重启并验证服务。

清理失败时恢复备份并重启，返回 `RolledBack`；自动恢复失败时保留受保护 journal 和备份并返回稳定错误。硬中断后重跑同一命令会先恢复旧事务，再重新执行维护。CPA 服务不变。

### shortcut

```powershell
& $cpaCli shortcut -Action Check  [-Root <path>] [-ShortcutPath <desktop.lnk>] [-Json]
& $cpaCli shortcut -Action Ensure [-Root <path>] [-ShortcutPath <desktop.lnk>] [-Json]
```

`Check` 严格零写入，状态包括 `Absent`、`Matching`、`Drifted`、`Adoptable`、`Conflict`。`Ensure` 使用 staging、复读和原子提交，自动备份并接管可识别的旧 CPA 快捷方式；未知冲突不会覆盖。`upgrade` 成功后自动对默认路径执行一次 Ensure，失败只追加 warning，不回滚已成功的运行时升级。

未传 `-ShortcutPath` 时使用当前用户桌面的 `CPA 本地启动.lnk`。快捷方式仅使用 PowerShell 7 (`pwsh.exe`)，未安装时明确报错，只保留一个可见窗口。canonical bootstrap 直接调用 bundled starter 的 Fast + Restart 模式，不执行 CLI `start` 的 ACL、hash、state、端口健康或 Manager readiness 预检；同路径 CPA/Manager 进程会先停止再重新启动。旧的 `CPA 本地启动（新版）.lnk` 在新名称成功建立后自动清理。

## installer

可信本地发行目录中的 installer 是自动在线检查之外的手工/离线 seam：

```powershell
& '<local release>\install.ps1' -Action Check  [-CodexHome <path>] [-StackRoot <path>] -Json
& '<local release>\install.ps1' -Action Update [-CodexHome <path>] [-StackRoot <path>] -Json
```

`Check` 严格只读；`Update` 原子更新 Skill、稳定 bootstrap 与 root registration，支持并发幂等和 hard-kill journal 恢复。显式指定新的空 `StackRoot` 时会先创建受保护 instance marker，使后续一键 `upgrade` 的自动迁移不会因 installer bootstrap 令目录非空而失败。installer 不升级或启动 CPA/Manager、不创建桌面快捷方式，也不从网络更新自身。

## schema v2

所有 runtime 命令至少返回：

```json
{
  "schemaVersion": 2,
  "operation": "status",
  "success": true,
  "outcome": "Healthy",
  "changed": false,
  "rolledBack": false,
  "recovered": false,
  "root": "E:\\CPA-Stack",
  "before": null,
  "after": null,
  "warnings": [],
  "error": null,
  "updaterVersion": "1.1.0"
}
```

允许的 `outcome`：

- `Healthy`
- `NoChange`
- `Changed`
- `RolledBack`
- `Blocked`
- `RecoveryRequired`
- `ManualRecoveryRequired`

`error` 非空时稳定为：

```json
{
  "code": "StableMachineCode",
  "message": "Human-readable message",
  "type": null,
  "phase": null
}
```

旧 bundled script 的 string、camelCase 或 PascalCase 错误会在 Result seam 规范化。stdout 必须只包含一个可识别 JSON object；多个 JSON 文档属于协议错误。输出禁止包含 secret。

非零退出码表示命令本身没有成功完成；`status` 检查到不健康状态不等于检查失败。
