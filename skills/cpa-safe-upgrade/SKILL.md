---
name: cpa-safe-upgrade
description: 在 Windows 上安全检查、迁移、恢复、启动或升级 CLIProxyAPI/CPA 与 CPA Manager Plus，并从用户已提供的可信本地发行目录原子检查或更新本 Skill、管理 CPA 桌面快捷方式或显式切换 LAN。仅当用户明确要求升级、迁移、恢复、更新 cpa-safe-upgrade、生成或修复 CPA 快捷方式、改变 LAN 暴露，或显式调用 cpa-safe-upgrade 时使用；普通端口查询、监控页面问题和未伴随上述目标的日常启动不要触发。
---

# CPA Safe Upgrade

## 执行边界

只使用 bundled `scripts/cpa-stack.ps1` 处理 CPA/Manager runtime。不要直接调用内部 `Test-*`、`Switch-*`、初始化或启动脚本，也不要临时重写停止、复制、迁移、切换或恢复逻辑。

更新 updater/Skill 时，只运行用户已提供并明确指出的可信本地发行目录中的 `install.ps1`。禁止本 Skill 下载、管道执行或在线替换自身代码；找不到本地 installer 时停止并请求其路径。在线查询与下载只允许由 runtime 事务执行器用于两个官方 CPA/Manager Release。

不要输出 secret、auth、完整配置、数据库、长日志或完整 HTML。未经明确授权，不删除 legacy 安装、历史目录或备份。

## 定位入口

从本次实际读取的 `SKILL.md` 绝对路径计算 skill 根目录；交互式 shell 中的 `$PSScriptRoot` 不是 skill 根目录：

```powershell
$skillRoot = Split-Path -Parent ((Resolve-Path -LiteralPath '<实际 SKILL.md 绝对路径>').Path)
$cpaCli = Join-Path $skillRoot 'scripts\cpa-stack.ps1'
```

managed root 优先使用用户明确给出的 `-Root`，否则让 CLI 按 `CPA_STACK_ROOT`、受保护 locator、默认 LocalAppData 专用目录解析。绝不假设盘符。

## v2 意图映射

用户只要求检查、审计或查看是否需要操作时，执行只读状态：

```powershell
& $cpaCli status -Root '<managed root>' -Json
```

用户已经明确要求恢复、迁移或升级时，不要先重复执行完整 `status`；直接调用对应事务一次：

```powershell
& $cpaCli recover -Root '<managed root>' -Json
& $cpaCli migrate -Root '<managed root>' -Json
& $cpaCli upgrade -Root '<managed root>' -Json
```

只依据 v2 envelope 决定下一步：

1. `success=true`：报告结果，不追加无关检查或操作。
2. `outcome=RecoveryRequired`：对同一 root 自动执行一次 `recover`；恢复成功后只重试一次原命令。再次要求恢复或返回 `ManualRecoveryRequired` 时停止。
3. `error.code=MigrationRequired`：停止并说明需要用户单独授权迁移/接管；升级授权不等于迁移授权。
4. 其他 `success=false`：停止并报告 `error.code`；不要用升级、启动或默认值掩盖故障。

CLI 内部的恢复、迁移和升级 interface 互不隐式调用；上面的单次恢复重试只是薄 Skill 对已授权用户意图的有限编排。

自动发现不唯一时，读取 [migration-request.md](references/migration-request.md)，生成不含 secret 值的临时 request JSON，再执行：

```powershell
& $cpaCli migrate -Root '<managed root>' -RequestPath '<request.json>' -Json
```

临时 request 只保存路径；使用后删除本次创建的 request。不要删除用户提供的 secrets 文件。

如果结果为未知版本替换阻断，先解释 latest stable 可能低于本机预发布版。只有用户再次明确接受后执行：

```powershell
& $cpaCli upgrade -Root '<managed root>' -AllowUnknownVersionReplacement -Json
```

`start` 只启动已接管且无 pending 的栈，不会隐式恢复：

```powershell
& $cpaCli start -Root '<managed root>' -NoBrowser
```

## 独立可选操作

快捷方式与 LAN 永远不并入 migrate 或 upgrade。

先只读检查明确的桌面快捷方式路径。首次不存在时，或后续检测到 drift 时，只有获得写入/接管授权后才 Ensure；`AdoptExisting` 需要单独明确授权：

```powershell
& $cpaCli shortcut -Action Check -Root '<managed root>' -ShortcutPath '<desktop .lnk>' -Json
& $cpaCli shortcut -Action Ensure -Root '<managed root>' -ShortcutPath '<desktop .lnk>' -Json
```

只有解释局域网暴露风险并得到明确授权后才切到 LAN；恢复 Loopback 也使用同一独立操作：

```powershell
& $cpaCli lan -Action Set -Mode Lan -Root '<managed root>' -Json
& $cpaCli lan -Action Set -Mode Loopback -Root '<managed root>' -Json
```

## 本地更新 updater/Skill

用户提供可信本地发行目录后，先运行严格只读 Check：

```powershell
& '<local release>\install.ps1' -Action Check -CodexHome '<codex home>' -StackRoot '<managed root>' -Json
```

只有用户明确授权更新后才运行：

```powershell
& '<local release>\install.ps1' -Action Update -CodexHome '<codex home>' -StackRoot '<managed root>' -Json
```

installer 只更新 Skill、稳定 launcher 与 root registration；它不升级正式 CPA/Manager、不改变 LAN，也不生成桌面快捷方式。若存在 installer recovery pending，让同一个本地 installer 的 `Update` 收敛事务，不要手工混合复制目录。

## 安全与诊断

发布审查、ACL/进程/数据安全判断或恢复诊断时读取 [safety-model.md](references/safety-model.md)。只有遇到具体失败时读取 [troubleshooting.md](references/troubleshooting.md)。

候选端口为执行器内部动态高位 loopback 资源，不作为用户接口、报告字段或固定端口假设。正式端口来自 managed stack 配置。

## 最终报告

简洁报告：

- `operation`、`outcome`、`root`、`changed`、`rolledBack`、`recovered`；
- 可用的 `before` / `after`、版本与 hash；
- shortcut 或 LAN 是否发生用户授权的变化；
- `warnings`、`error.code` 和未完成事项。

不要报告动态候选端口、内部 journal 路径、secret 或长日志。
