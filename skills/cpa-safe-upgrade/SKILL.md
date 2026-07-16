---
name: cpa-safe-upgrade
description: 在 Windows 上安全发现、迁移、启动、恢复和自动升级 CLIProxyAPI/CPA 与 CPA Manager Plus。仅当用户明确要求升级 CPA、升级 CLIProxyAPI、升级 CPA Manager Plus、把已有安装迁移到任意盘的统一 CPA Stack、恢复中断升级，或显式调用 cpa-safe-upgrade 时使用。用户只是询问端口、监控、管理页面或普通启动问题时不要触发，除非同时明确要求升级、迁移或恢复。
---

# CPA Safe Upgrade

只使用 bundled `scripts/cpa-stack.ps1` 作为公开执行入口。它把发现、SQLite 快照、候选验证、正式切换、中断恢复和结构化结果封装成稳定命令。

不要临时重写迁移或切换脚本。不要直接调用 `Test-*` 或 `Switch-*` 内部脚本。

读取本文件后，先用实际 `SKILL.md` 绝对路径确定 skill 根目录。交互式 shell 中的 `$PSScriptRoot` 不是 skill 根目录，不能用它定位入口：

```powershell
$skillRoot = Split-Path -Parent ((Resolve-Path -LiteralPath '<本次实际读取的 SKILL.md 绝对路径>').Path)
```

## 根目录解析

按以下优先级确定 managed root：

1. 用户明确指定的路径，通过 `-Root` 传入。
2. `CPA_STACK_ROOT`。
3. 上次成功初始化写入的受保护 root locator。
4. `%LOCALAPPDATA%\CPAStack`。

绝不能假设盘符。C/D/E 盘、空格和非 ASCII 路径均可使用，但目标必须位于本地 NTFS 或 ReFS。

## 只读发现

任何有状态操作前先执行：

```powershell
& (Join-Path $skillRoot 'scripts\cpa-stack.ps1') status -Root '<用户指定根目录>' -Json
```

只有用户没有指定目录时才省略 `-Root`。

需要预览时执行：

```powershell
& (Join-Path $skillRoot 'scripts\cpa-stack.ps1') plan -Root '<用户指定根目录>' -Json
```

`plan` 必须保持完全只读。

## 自动升级

只有收到明确升级授权后才执行：

```powershell
& (Join-Path $skillRoot 'scripts\cpa-stack.ps1') upgrade -Root '<用户指定根目录>' -Json
```

如果 `status` 表明需要首次迁移，且发现了仍指向 legacy launcher 的 CPA 桌面快捷方式，执行前必须向用户说明：默认不会修改该快捷方式；迁移后再次使用它可能重新启动旧 runtime/data。只有用户明确授权更新快捷方式后，才在上述升级命令的 `-Json` 前加入 `-UpdateDesktopShortcut`。

如果用户不授权，不得添加该开关；迁移完成后必须明确要求用户停用旧快捷方式，并统一使用下文“恢复和启动”中的 canonical `start` 命令。

统一入口会完成：

- 根据 8317/18317 正式监听进程和启动入口发现真实安装。
- 有 pending journal 时优先恢复中断事务。
- 对早期版本已有 canonical runtime/data、但缺少实例 marker 的根目录，验证固定路径、正式进程和记录 hash 后，用无密钥 journal 原地接管并加固 ACL；不重新复制数据。
- 未接管但来源唯一且健康时，先用当前版本迁入 canonical root。
- 在线查询两个官方 GitHub Release。
- 校验 SHA256，并在解压前检查 ZIP 路径和大小边界。
- 在仅回环可访问的临时端口验证 CPA 和 Manager 候选。
- 为 Manager 创建 SQLite online backup。
- 原子切换正式 runtime。
- 正式切换失败时，在返回前恢复旧的健康 runtime。

发现、密钥、文件系统、Python、磁盘空间、下载、checksum 或候选验证失败时，不得停止正式服务。

如果结果提示无法证明版本单调，说明当前二进制版本不可可靠识别。先向用户明确解释“latest stable 可能低于本机预发布版”的风险；只有用户明确同意替换未知版本后，才重试：

```powershell
& (Join-Path $skillRoot 'scripts\cpa-stack.ps1') upgrade `
  -Root '<用户指定根目录>' `
  -AllowUnknownVersionReplacement `
  -Json
```

不得自行推断或静默添加这个开关。

## 显式迁移来源

如果进程和启动信息无法唯一定位来源，显式传入：

```powershell
& (Join-Path $skillRoot 'scripts\cpa-stack.ps1') init `
  -Root 'E:\CPA-Stack' `
  -SourceCpaRuntime 'E:\apps\cpa' `
  -SourceCpaConfig 'E:\config\cpa.yaml' `
  -SourceManagerRuntime 'E:\apps\manager-plus' `
  -SourceManagerData 'E:\data\manager-plus' `
  -SecretsInputPath "$HOME\cpa-secrets.json" `
  -Json
```

Secrets input 必须分别包含三个非空字段：

```json
{
  "cpaClientApiKey": "...",
  "cpaManagementKey": "...",
  "managerAdminKey": "..."
}
```

禁止输出或转述它们的值。初始化器不会擅自删除用户提供的 secrets 文件。

只有用户明确授权修改桌面快捷方式时才传 `-UpdateDesktopShortcut`；未授权时，最终报告必须提示停用旧快捷方式并改用 canonical `start`。只有解释局域网暴露风险并得到明确授权后才传 `-ExposeToLan`；候选端口始终只允许 loopback。

## 恢复和启动

如果 status 报告 pending journal，不要直接运行 canonical launcher。调用 upgrade 入口，让恢复流程先收敛事务。

启动已接管栈：

```powershell
& (Join-Path $skillRoot 'scripts\cpa-stack.ps1') start -Root '<用户指定根目录>' -NoBrowser
```

## 安全边界

- 要求专用本地 NTFS/ReFS 根目录；拒绝 UNC、盘符根、Windows/Program Files 子树、用户主目录本身、Git worktree 和 reparse traversal。默认的 LocalAppData 专用子目录仍受支持。
- managed root 只允许当前用户、SYSTEM 和本地 Administrators。
- CPA `auth` 与可选 `plugins` 代码树递归拒绝 reparse point，并对每个文件和子目录加固、校验 owner 与 ACL。
- 首次迁移允许 legacy 源保留普通只读权限，但拒绝非受信主体修改或替换 runtime/config/auth/plugins；候选退出后用递归 manifest、config hash 与 host 绑定正式 target，不再从在线 legacy 源二次复制。
- marker、current 与所有 pending journal 必须绑定同一个 instanceId；缺失或冲突时停止恢复。
- 迁移时以正式监听进程作为最强来源证据。
- 即使三个 key 当前相同，也必须保持三个变量和用途分离。
- 未经明确授权，不删除旧安装、日志、仓库或备份。
- 只有端口 owner 的路径与当前事务预期一致时才允许停止进程。
- 不以网页版本号或页面文字判断程序版本。
- 对话中禁止输出 secret、auth 内容、完整配置、数据库、长日志和完整 HTML。

诊断阻断或审查发布时读取 [references/safety-model.md](references/safety-model.md)。只有遇到具体失败时才读取 [references/troubleshooting.md](references/troubleshooting.md)。

## 最终报告

简洁报告：

- managed root，以及是否发生迁移；
- 是否发生旧 canonical 原地接管与 launcher 刷新；
- 新旧版本和 hash；
- 候选端口与正式端口结果；
- SQLite、历史数据水位（空数据库也合法）和 collector 检查；
- 是否自动回滚；
- current 与 last-known-good 路径；
- 用户明确授权的 shortcut 或 LAN 暴露变化；
- warning 和未完成事项。

不要粘贴长日志或任何 secret。
