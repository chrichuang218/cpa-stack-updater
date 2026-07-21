---
name: cpa-safe-upgrade
description: 在 Windows 上安全检查、迁移、恢复、启动或升级 CLIProxyAPI/CPA 与 CPA Manager Plus，在 upgrade 前从固定官方 Release 自动验证并更新本 Skill，也支持可信本地发行目录的原子手工更新、CPA 桌面快捷方式管理和显式 LAN 切换。仅当用户明确要求升级、迁移、恢复、更新 cpa-safe-upgrade、生成或修复 CPA 快捷方式、改变 LAN 暴露，或显式调用 cpa-safe-upgrade 时使用；普通端口查询、监控页面问题和未伴随上述目标的日常启动不要触发。
---

# CPA Safe Upgrade

## 执行边界

只使用 bundled `scripts/cpa-stack.ps1` 处理 CPA/Manager runtime。不要直接调用内部 `Test-*`、`Switch-*`、初始化或启动脚本，也不要临时重写停止、复制、迁移、切换或恢复逻辑。唯一例外是 installer 管理的 canonical desktop bootstrap；它按固定契约内部调用 starter 的 Fast 模式，Codex 不手工复刻或直接调用该入口。

`upgrade` 的固定前置步骤允许 bundled self-update 模块只查询 `chrichuang218/cpa-stack-updater` 的最新稳定 Release；只有版本更高，且固定名称 ZIP、`checksums.txt`、两个 GitHub SHA256 digest 与包内 VERSION 全部一致时，才调用已下载到本地的 `install.ps1` 原子更新并用新版 CLI 重执行一次。禁止下载源码分支、管道执行远程脚本、接受 fork/预发布版本或在校验/安装失败后继续运行旧 updater。用户单独要求手工更新 Skill 时仍只运行其明确提供的可信本地发行目录。

不要输出 secret、auth、完整配置、数据库、长日志或完整 HTML。未经明确授权，不删除 legacy 安装、历史目录或备份。

## 定位入口

从本次实际读取的 `SKILL.md` 绝对路径计算 skill 根目录；交互式 shell 中的 `$PSScriptRoot` 不是 skill 根目录：

```powershell
$skillRoot = Split-Path -Parent ((Resolve-Path -LiteralPath '<实际 SKILL.md 绝对路径>').Path)
$cpaCli = Join-Path $skillRoot 'scripts\cpa-stack.ps1'
```

managed root 优先使用用户明确给出的 `-Root`，否则让 CLI 按 `CPA_STACK_ROOT`、受保护 locator、默认 LocalAppData 专用目录解析。绝不假设盘符。

## 操作映射

用户只要求检查、审计或查看是否需要操作时，执行只读状态：

```powershell
& $cpaCli status -Root '<managed root>' -Json
```

用户要求升级时，不要先执行 `status`，也不要询问恢复、迁移或未知版本替换；只调用一次自动升级入口：

```powershell
& $cpaCli upgrade -Root '<managed root>' -Json
```

`upgrade` 自动执行 `updater → recover → migrate → runtime upgrade → shortcut Ensure`：先检查并按上述信任链更新 updater；有单一可恢复 pending 时恢复一次，未建立 canonical stack 时迁移一次，最后升级 runtime。运行时升级成功后自动创建或更新当前用户桌面的 `CPA 本地启动.lnk`，识别到旧 CPA 快捷方式时自动备份并接管，不再询问。快捷方式维护失败只追加 warning，不回滚已经成功的运行时升级。

只依据最终结构化结果（`schemaVersion=2`）报告：

1. `success=true`：报告结果，不追加无关检查或操作。
2. `success=false`：停止并报告 `automation.failedStep` 与 `error.code`，不要询问是否绕过真正的安全失败。

自动发现不唯一时，读取 [migration-request.md](references/migration-request.md)，生成不含 secret 值的临时 request JSON，再执行：

```powershell
& $cpaCli upgrade -Root '<managed root>' -RequestPath '<request.json>' -Json
```

临时 request 只保存路径；使用后删除本次创建的 request。不要删除用户提供的 secrets 文件。

真正的安全失败仍立即停止：updater Release 查询/校验/安装/重执行失败、歧义 journal、未知端口 owner、不可信 ACL/reparse、checksum、候选健康、磁盘/路径预算、SQLite 水位或自动回滚失败。不要吞错、伪成功或自动放宽这些门禁。

用于 Windows 定时任务时，通过 PowerShell 宿主以 `-NonInteractive` 调用同一个 `upgrade` 命令；`-NonInteractive` 是宿主参数，必须放在 `-File` 之前，不能传给 `cpa-stack.ps1`：

```powershell
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cpaCli upgrade -Json
```

调用本身同时授权按固定信任链更新 updater，无需逐次确认。退出码 `0` 表示 updater/runtime 升级成功或已经最新；非零表示真实失败。命令不读取 stdin、不打开浏览器；下一次调度会自动处理单一可恢复 pending。

`start` 只启动已接管且无 pending 的栈，不会隐式恢复：

```powershell
& $cpaCli start -Root '<managed root>' -NoBrowser
```

## 桌面快速启动与独立操作

用户说“帮我创建桌面启动方式”“创建 CPA 快捷方式”或同义表达时，直接执行默认路径的 `Ensure`，不要先 `Check`，不要询问是否写入或接管：

```powershell
& $cpaCli shortcut -Action Ensure -Root '<managed root>' -Json
```

默认路径是当前用户桌面的 `CPA 本地启动.lnk`。Ensure 自动创建、修复 drift，或备份并接管可识别的旧 CPA 启动方式；旧的 `CPA 本地启动（新版）.lnk` 在新名称成功建立后自动清理，完全无关的未知冲突仍明确失败且不覆盖。生成的快捷方式优先使用 PowerShell 7 (`pwsh.exe`)，未安装时回退 Windows PowerShell 5.1，只保留一个可见窗口。canonical bootstrap 直接调用 bundled starter 的 Fast 模式，不执行 `cpa-stack status/start`、ACL、hash、端口健康或 Manager readiness 预检；进程存在时立即复用，缺失时直接启动并打开页面。完整检查只在 CLI `start` 和更新事务中执行。

只有用户明确要求只读审计快捷方式时才执行：

```powershell
& $cpaCli shortcut -Action Check -Root '<managed root>' -ShortcutPath '<desktop .lnk>' -Json
```

LAN 永远不并入 migrate、upgrade 或快捷方式操作。

只有解释局域网暴露风险并得到明确授权后才切到 LAN；恢复 Loopback 也使用同一独立操作：

```powershell
& $cpaCli lan -Action Set -Mode Lan -Root '<managed root>' -Json
& $cpaCli lan -Action Set -Mode Loopback -Root '<managed root>' -Json
```

## 手工更新 updater/Skill

用户提供可信本地发行目录后，先运行严格只读 Check：

```powershell
& '<local release>\install.ps1' -Action Check -CodexHome '<codex home>' -StackRoot '<managed root>' -Json
```

只有用户明确授权更新后才运行：

```powershell
& '<local release>\install.ps1' -Action Update -CodexHome '<codex home>' -StackRoot '<managed root>' -Json
```

这是自动 `upgrade` 之外的离线/手工入口。installer 只更新 Skill、稳定 launcher 与 root registration；它不升级正式 CPA/Manager、不改变 LAN，也不生成桌面快捷方式。若存在 installer recovery pending，让同一个本地 installer 的 `Update` 收敛事务，不要手工混合复制目录。

## 安全与诊断

发布审查、ACL/进程/数据安全判断或恢复诊断时读取 [safety-model.md](references/safety-model.md)。只有遇到具体失败时读取 [troubleshooting.md](references/troubleshooting.md)。

候选端口为执行器内部动态高位 loopback 资源，不作为用户接口、报告字段或固定端口假设。正式端口来自 managed stack 配置。

## 最终报告

简洁报告：

- `operation`、`outcome`、`root`、`changed`、`rolledBack`、`recovered`；
- updater 是否检查/更新及其 before、after、available 版本；
- 可用的 `before` / `after`、版本与 hash；
- shortcut 是否自动创建/更新、LAN 是否发生用户授权的变化；
- `warnings`、`error.code` 和未完成事项。

不要报告动态候选端口、内部 journal 路径、secret 或长日志。
