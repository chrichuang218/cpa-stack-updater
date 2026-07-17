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

显式恢复一个可证明的中断事务，包括初始化/升级及其从属 switch artifact、旧 canonical 接管和 LAN 配置。无 pending 时返回 `NoChange`。journal 类型歧义、instanceId/path/hash 不一致或恢复后仍中断时返回 `ManualRecoveryRequired`。恢复只调用 recovery-only interface，不会开始新迁移、升级或 LAN 变更；也不会由 `upgrade` 或 `start` 隐式调用。

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
& $cpaCli upgrade [-Root <path>] [-AllowUnknownVersionReplacement] [-Json]
```

只升级已经建立且健康、无 pending 的 canonical stack。不会隐式恢复、迁移、接管快捷方式或修改 LAN。

`-AllowUnknownVersionReplacement` 仅在用户理解预发布版可能被 latest stable 替换并再次明确授权后使用。

### start

```powershell
& $cpaCli start [-Root <path>] [-NoBrowser] [-Json]
```

启动或复用已接管栈。pending transaction 会返回 `RecoveryRequired`，不会自动恢复。

### shortcut

```powershell
& $cpaCli shortcut -Action Check  [-Root <path>] [-ShortcutPath <desktop.lnk>] [-Json]
& $cpaCli shortcut -Action Ensure [-Root <path>] [-ShortcutPath <desktop.lnk>] [-AdoptExisting] [-Json]
```

`Check` 严格零写入，状态包括 `Absent`、`Matching`、`Drifted`、`Adoptable`、`Conflict`。`Ensure` 使用 staging、复读和原子提交；接管可识别旧快捷方式需要显式 `-AdoptExisting`，未知冲突不会覆盖。

推荐总是显式传 `-ShortcutPath`。未传时使用当前用户桌面的 `CPA 本地启动（新版）.lnk`。

### lan

```powershell
& $cpaCli lan -Action Set -Mode Loopback [-Root <path>] [-Json]
& $cpaCli lan -Action Set -Mode Lan      [-Root <path>] [-Json]
```

独立配置 CPA 与 Manager 的正式绑定并进行真实健康验证；失败时恢复旧配置和健康服务。LAN journal 在配置写入前记录受保护备份与 hash，硬中断由公开 `recover` 收敛；`NoChange` 同样验证实际 listener，不只比较文件。LAN 需要单独风险说明和授权。候选验证始终只允许 loopback。

## v0.2 兼容命令

以下名称只保留一个版本，并返回 schema v2：

- `doctor`、`plan` → `status`
- `init` → `migrate`
- `register-root` → 由 `install.ps1` 管理的兼容写入

它们会返回 legacy warning，不属于 v1 支持接口，后续可直接删除且不提供兼容保证。旧组合参数 `-UpdateDesktopShortcut`、`-ExposeToLan` 不再执行隐式副作用；请改用独立 `shortcut` 与 `lan` 命令。

每个命令有参数 allowlist。无关参数返回 `UnsupportedCommandParameter`，不会被静默忽略。

## installer

可信本地发行目录中的 installer 与 runtime CLI 是两个 seam：

```powershell
& '<local release>\install.ps1' -Action Check  [-CodexHome <path>] [-StackRoot <path>] -Json
& '<local release>\install.ps1' -Action Update [-CodexHome <path>] [-StackRoot <path>] -Json
```

`Check` 严格只读；`Update` 原子更新 Skill、稳定 bootstrap 与 root registration，支持并发幂等和 hard-kill journal 恢复。显式指定新的空 `StackRoot` 时会先创建受保护 instance marker，使随后单独授权的 `migrate` 不会因 installer bootstrap 令目录非空而失败。installer 不升级或启动 CPA/Manager、不启用 LAN、不创建桌面快捷方式，也不从网络更新自身。

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
  "updaterVersion": "1.0.1"
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
