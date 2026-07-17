# CPA Stack Updater

[![CI](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml/badge.svg)](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)](https://github.com/chrichuang218/cpa-stack-updater)

[English](README.en.md)

面向 Windows 的 CLIProxyAPI/CPA 与 CPA Manager Plus 安全迁移、恢复和升级工具。v0.2 将交互收敛为“薄 Skill + 小而稳定的事务执行器”：Skill 只判断该调用哪个公开命令，复杂的发现、ACL、SQLite 快照、候选验证、切换和回滚都封装在 bundled PowerShell 中。

> 本项目是社区工具，与两个上游项目不存在官方隶属或背书关系。

## v0.2 架构

```text
status（只读）
  ├─ requiredOperation=recover ──> recover
  ├─ requiredOperation=migrate ──> migrate
  └─ canonical healthy ──────────> upgrade

shortcut / lan / start / Skill installer 均为独立操作
```

`upgrade` 不会隐式迁移、恢复、修改快捷方式或启用 LAN。每个有状态操作都必须单独执行，授权和失败范围清晰。

## 安全保证

- 候选进程使用动态分配、未占用的高位 loopback 端口；候选端口不是固定用户接口。
- 正式端口来自 managed stack 配置，不假设盘符或端口。
- 只从两个硬编码官方上游读取 Release，并校验 HTTPS、checksum 与 SHA256。
- ZIP 解压前检查路径穿越、文件数量与总大小。
- Manager 数据使用 SQLite online backup，并验证 `quick_check`、必需业务表和历史水位。
- pending journal 绑定 instanceId 且不保存 secret，支持硬中断恢复。
- 停服前固定已验证 listener 的 `Process`；路径/PID 不匹配时绝不终止未知进程。
- 长驻服务无控制台运行，只继承显式指向 `NUL` 的标准句柄。
- managed root、runtime、auth/plugins、Manager data 和关键父目录执行 owner、DACL 与 reparse 检查。
- Windows PowerShell 5.1 路径预算在正式停服前完成。
- 正式切换失败时自动恢复上一健康 runtime；未经授权不删除 legacy 安装或历史目录。
- updater installer 只更新 Skill、稳定 launcher 与 root registration，不升级正式 CPA/Manager，也不改变 LAN。

完整模型见 [docs/safety-model.md](docs/safety-model.md)。

## 要求

- Windows 10/11 x64
- Windows PowerShell 5.1 或 PowerShell 7
- Python 3.10+
- 本地 NTFS 或 ReFS
- 迁移场景下已有 CLIProxyAPI 与 CPA Manager Plus

仓库不包含第三方 exe、真实配置、密钥、数据库或遥测代码。

## 安装或更新 Skill

从 [Releases](https://github.com/chrichuang218/cpa-stack-updater/releases/latest) 下载并解压可信发行包。先做严格只读检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Action Check `
  -StackRoot 'E:\CPA-Stack' `
  -Json
```

确认后原子安装或更新：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Action Update `
  -StackRoot 'E:\CPA-Stack' `
  -Json
```

可用 `-CodexHome` 指定非默认 Codex 目录。安装器采用双槽与受保护 journal；并发 Update 只提交一次，硬中断后再次 Update 会先恢复。显式传入全新的空 `StackRoot` 时，安装器会创建受保护 instance marker 与稳定 launcher，使后续显式 `migrate` 能进入同一 root；它不会安装或启动 CPA runtime。稳定 launcher 写入 `<StackRoot>\ops\Start-CPA-Stack.ps1`，且不会创建桌面快捷方式。

`Bypass` 只作用于本次进程，不修改长期执行策略。安装完成后可删除解压目录。

## 使用 v2 CLI

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cpaCli = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
$root = 'E:\CPA-Stack'
```

`E:` 只是示例；C、D、E 盘、空格和非 ASCII 路径均可，目标必须通过本地文件系统安全检查。

### 1. 只读检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli status -Root $root -Json
```

`status` 成功完成检查时退出 0；栈不健康会通过 `outcome=Blocked` 表达。检查协议本身失败时 `success=false` 且退出非零。查看 `requiredOperation` 决定下一条命令。

### 2. 显式恢复或迁移

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli recover -Root $root -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli migrate -Root $root -Json
```

仅执行 `status` 要求且用户已授权的操作。自动发现不唯一时，用 `-RequestPath` 提供显式迁移 request；request 只保存来源路径、secrets 文件路径和可选正式端口，不保存 secret 值。格式见 [migration-request.md](skills/cpa-safe-upgrade/references/migration-request.md)。

### 3. 升级健康 canonical stack

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root $root -Json
```

未知版本默认阻断，避免把预发布版误降到 latest stable。用户理解并再次明确接受后才使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade `
  -Root $root `
  -AllowUnknownVersionReplacement `
  -Json
```

### 4. 启动

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start -Root $root -NoBrowser
```

`start` 不会隐式恢复 pending transaction。

## 桌面快速启动

installer 首次生成稳定 launcher；桌面快捷方式由独立命令管理。先检查，首次不存在或后续 drift 时再 Ensure：

```powershell
$shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CPA 本地启动（新版）.lnk'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli shortcut `
  -Action Check -Root $root -ShortcutPath $shortcut -Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli shortcut `
  -Action Ensure -Root $root -ShortcutPath $shortcut -Json
```

识别到可接管的旧快捷方式时，只有明确授权后才添加 `-AdoptExisting`。未知冲突不会被覆盖。

## LAN 暴露

LAN 是独立高风险操作。解释风险并得到明确授权后才切换：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli lan -Action Set -Mode Lan -Root $root -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli lan -Action Set -Mode Loopback -Root $root -Json
```

候选验证始终只允许 loopback。

## JSON 契约

所有公开命令返回 schema v2 envelope：

```json
{
  "schemaVersion": 2,
  "operation": "upgrade",
  "success": true,
  "outcome": "Changed",
  "changed": true,
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

`error` 非空时稳定包含 `code` 与 `message`。操作专属详情用于诊断；不要依赖未文档化的内部 journal 或动态候选端口。

完整语法见 [docs/cli.md](docs/cli.md)。

## 卸载

```powershell
$uninstaller = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\Uninstall-CpaSafeUpgrade.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -Yes
```

卸载只移除带有效 ownership marker 的 Skill 与回滚槽，不触碰 CPA runtime、Manager 数据或 legacy 安装。

## 根目录

优先级：

1. `-Root`
2. `CPA_STACK_ROOT`
3. 受保护 root locator
4. `%LOCALAPPDATA%\CPAStack`

盘符根、UNC、Git worktree、Windows/Program Files 子树、用户主目录本身和不受支持的文件系统会被拒绝。

## 测试与发布

测试使用隔离 root/state/lock、动态高位 loopback 端口和 `KILL_ON_JOB_CLOSE` Job Object；正式端口、正式 PID、正式 root 与控制文件是发布阻断保护项。CI 在 Windows PowerShell 5.1 和 PowerShell 7 运行完整套件。

v1.0.0 是首个受支持版本。0.x 仅为开发历史，不承诺旧 updater 安装、journal 或事务状态兼容；现有 CPA/Manager 数据仍可通过正式 `migrate` 流程迁入任意本地盘的 managed root。

## 安全反馈

请按 [SECURITY.md](SECURITY.md) 私下报告漏洞。Issue 中不要上传 key、`data.key`、SQLite、auth、完整配置或原始请求日志。

## License

MIT。上游项目和下载的二进制继续遵循各自许可证。
