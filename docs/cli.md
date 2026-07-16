# CLI 使用说明

安装后以 installer 返回的 `stableCliPath` 为唯一入口。下文 `\.\cpa-stack.ps1` 仅是仓库源码目录中的开发简写；普通用户应执行 `$CODEX_HOME\skills\cpa-safe-upgrade\scripts\cpa-stack.ps1`（未设置 `CODEX_HOME` 时使用 `$HOME\.codex`）。

## 根目录解析

`-Root` 的优先级高于 `CPA_STACK_ROOT`、已登记的 root locator 和 `%LOCALAPPDATA%\CPAStack`。示例中的 `E:` 不是固定要求，必须换成当前电脑真实存在的本地 NTFS/ReFS 目录。

## 只读命令

```powershell
.\cpa-stack.ps1 status -Root 'E:\CPA-Stack' -Json
.\cpa-stack.ps1 plan   -Root 'E:\CPA-Stack' -Json
```

`plan` 不会修改服务、文件、快捷方式、配置或 root locator。

## 自动升级

```powershell
.\cpa-stack.ps1 upgrade -Root 'E:\CPA-Stack' -Json
```

如果唯一发现到一个健康但尚未接管的安装，`upgrade` 会先只迁移当前版本，重新检查 canonical 栈健康状态，再以独立事务执行版本升级。

如果发现的是本工具早期版本创建的 canonical root（已有固定 runtime/data 与 `current.json`，但缺少新版实例 marker），`upgrade` 会先验证服务、路径和 hash，再通过 `adopt.pending.json` 原地补齐 `instanceId`、ACL 与最新 canonical launcher。该流程不复制或删除正式数据，并支持中断后重入。

当旧程序版本无法可靠识别、且 hash 与 latest stable 不同时，默认阻断替换，防止误降级。用户理解风险并明确决定替换未知版本后，才使用：

```powershell
.\cpa-stack.ps1 upgrade `
  -Root 'E:\CPA-Stack' `
  -AllowUnknownVersionReplacement `
  -Json
```

## 显式指定迁移来源

```powershell
.\cpa-stack.ps1 init `
  -Root 'E:\CPA-Stack' `
  -SourceCpaRuntime 'D:\old\cpa' `
  -SourceCpaConfig 'D:\old\config.yaml' `
  -SourceManagerRuntime 'D:\old\manager-plus' `
  -SourceManagerData 'D:\old\manager-data' `
  -SecretsInputPath "$HOME\cpa-secrets.json" `
  -Json
```

Secrets 文件必须分别包含 `cpaClientApiKey`、`cpaManagementKey` 和 `managerAdminKey`。它只在本机读取，绝不会出现在结果中。

只有旧 PowerShell launcher 以简单字符串变量保存 Manager admin key 与 CPA management key、且 CPA config 包含 client API key 时，才可用 `-LegacyStartScript` 代替 `-SecretsInputPath`。

## 可选行为

- `-UpdateDesktopShortcut`：允许更新显式传入或发现到的 CPA 桌面快捷方式。更新后的 `.lnk` 固定使用 `powershell.exe -NonInteractive -WindowStyle Hidden` 启动 canonical launcher；手工 CLI 仍在当前终端显示输出。
- `-ExposeToLan`：允许正式服务保留或使用非 loopback 绑定；候选服务仍只允许 loopback。
- `-NoBrowser`：`start` 时不打开 Manager 页面。
- `-AllowUnknownVersionReplacement`：明确允许替换无法证明版本单调的旧二进制；不得默认添加。

这些选项都不会被静默推断。

## JSON 契约

所有公开 CLI 命令（包括 `start`）都返回带版本的 JSON，至少包含：

```json
{
  "schemaVersion": 1,
  "updaterVersion": "0.1.1",
  "command": "upgrade",
  "success": true,
  "changed": true,
  "root": "E:\\CPA-Stack",
  "warnings": [],
  "error": null
}
```

即使 root locator 损坏或 `-Root` 非法，`-Json` 调用也会返回结构化失败。输出中禁止出现 secret。非零进程退出码表示请求没有成功完成；候选验证失败不代表正式服务发生过停机。
