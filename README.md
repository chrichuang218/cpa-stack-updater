# CPA Stack Updater

[![CI](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml/badge.svg)](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)](https://github.com/chrichuang218/cpa-stack-updater)

[English](README.en.md)

面向 Windows 的 CLIProxyAPI/CPA 与 CPA Manager Plus 安全自动升级工具。

新版本会先从官方 GitHub Release 下载并校验，再在仅本机可访问的临时端口启动候选版本。只有候选验证、SQLite 一致快照和数据兼容检查全部通过后，才切换正式服务；正式切换失败会自动恢复上一个健康版本。

> 本项目是社区工具，与两个上游项目不存在官方隶属或背书关系。

## 解决什么问题

手工升级经常留下多个运行目录、旧 ZIP、测试数据库、备份目录和启动脚本，最终不知道哪一份才是正式数据。本工具将其收敛成一个 canonical root：

```text
发现 -> 计划 -> 下载校验 -> 候选验证 -> SQLite 快照
     -> 原子切换 -> 正式验证 -> 提交
                           \-> 失败自动恢复
```

旧安装可以在 C、D、E 任意盘，也可以包含空格和中文。迁移时只接管当前正在运行的程序、配置、认证文件和正式 Manager 数据，不导入旧日志、历史下载和测试数据库。

## 安全保证

- 8318/18318 候选端口只绑定 `127.0.0.1`。
- 校验官方压缩包和 checksum 的 SHA256。
- 解压前检查路径穿越、文件数量和总大小。
- Manager 数据使用 SQLite online backup。
- 同一 Windows 账户跨登录会话文件锁阻止并发升级、安装和卸载。
- pending journal 支持硬中断恢复，绑定实例 ID 且不保存密钥。
- 候选测试后、正式切换前再次校验 exe hash。
- 整个管理根只允许当前用户、SYSTEM 和 Administrators 访问。
- 不会终止路径不匹配的未知端口进程。
- 未经单独明确授权，不删除旧安装和历史目录。

## 环境要求

- Windows 10/11 x64
- Windows PowerShell 5.1 或 PowerShell 7
- Python 3.10+
- 本地 NTFS 或 ReFS 磁盘
- 迁移场景下需要已有 CLIProxyAPI 和 CPA Manager Plus

普通安装不需要 Git；只有选择克隆仓库参与开发时才需要 Git。

仓库不包含任何第三方 exe、真实配置、密钥、数据库或遥测代码。

## 快速开始

从 [Releases](https://github.com/chrichuang218/cpa-stack-updater/releases/latest) 下载最新 `Source code (zip)` 并解压，在解压目录打开 PowerShell，然后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -StackRoot 'E:\CPA-Stack'
```

`Bypass` 只对这一次安装进程生效，不会修改系统或当前用户的长期执行策略。开发者也可以用 Git 克隆仓库后运行同一命令。

安装完成后，解压目录可以删除。以后始终使用已安装的稳定 CLI；每次打开新 PowerShell 先定义：

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cpaCli = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
```

`E:` 只是示例；请换成这台电脑真实存在的本地 NTFS/ReFS 目录。安装器会为 Skill 写入所有权标记，卸载时只删除由本工具安装且标记有效的目录，不会触碰 CPA runtime 或数据。

先只读查看计划：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli plan -Root 'E:\CPA-Stack' -Json
```

确认后迁移并升级。默认不会修改桌面快捷方式；如果旧快捷方式仍指向 legacy launcher，重启或再次点击它可能重新启动旧 runtime/data。首次迁移前，请明确选择一种启动方式：

- 如果允许工具把发现到的 CPA 桌面快捷方式更新为 canonical launcher，请执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root 'E:\CPA-Stack' -UpdateDesktopShortcut -Json
```

- 如果不授权修改快捷方式，请执行不带该开关的升级；以后不要再使用旧快捷方式，统一通过 canonical CLI 启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root 'E:\CPA-Stack' -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start -Root 'E:\CPA-Stack'
```

如果旧二进制没有可靠版本信息，工具会先阻断，避免把 nightly/预发布版误降级到 latest stable。理解风险并明确决定替换未知版本后，再使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root 'E:\CPA-Stack' -AllowUnknownVersionReplacement -Json
```

首次成功后会登记根目录，以后可以直接：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli status -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Json
```

如果目标目录来自本工具的早期版本、已有 canonical runtime/data 但还没有 `instanceId` marker，`upgrade` 会先验证固定路径、运行进程和已记录 hash，再用无密钥 journal 原地接管并加固 ACL；不会重新复制或清空 Manager 数据。

## Codex Skill

`install.ps1` 会把 `cpa-safe-upgrade` 安装到 `$CODEX_HOME\skills`；如果没有设置 `CODEX_HOME`，则安装到 `$HOME\.codex\skills`。

示例：

> 使用 $cpa-safe-upgrade，发现我当前的 CPA，把它迁移到 E:\CPA-Stack，然后安全升级 CPA 和 Manager Plus。

Skill 只调用统一的 `cpa-stack.ps1`，不会临时手写停止、复制和启动命令。

更新 updater 时，下载新 Release 并再次运行 `install.ps1`；安装器会原子替换同一个稳定路径。卸载无需保留原 ZIP：

```powershell
$uninstaller = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\Uninstall-CpaSafeUpgrade.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -Yes
```

卸载只移除带有效所有权 marker 的 Skill 与上一版本副本，不触碰 CPA runtime 或 Manager 数据。

## 任意目录

根目录优先级：

1. 命令行 `-Root`
2. 环境变量 `CPA_STACK_ROOT`
3. 上次初始化成功后保存的受保护 locator
4. `%LOCALAPPDATA%\CPAStack`

以下位置会被拒绝：盘符根目录、UNC、exFAT、Git 工作区、Windows/Program Files 子树和用户主目录本身。默认的 `%LOCALAPPDATA%\CPAStack` 专用子目录仍可使用。

详细命令见 [docs/cli.md](docs/cli.md)，安全模型见 [docs/safety-model.md](docs/safety-model.md)。

## 发布阶段

`v0.1.x` 是公开加固阶段，真实验证按 5 台、20 台、100 台逐步扩展。没有真实恢复证据前，不宣称已经覆盖所有 Windows 环境。

## 安全反馈

请按 [SECURITY.md](SECURITY.md) 私下报告漏洞。Issue 中不要上传 key、`data.key`、SQLite、auth 文件、完整配置或原始请求日志。

## License

MIT。上游项目和下载的二进制继续遵循各自许可证。
