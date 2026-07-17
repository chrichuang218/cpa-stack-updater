# 显式迁移请求

只有自动发现无法唯一确定来源时才创建 request。request 只保存路径和可选正式端口，不保存任何 secret 值。

```json
{
  "schemaVersion": 1,
  "sourceMode": "Explicit",
  "source": {
    "cpaRuntime": "D:\\old\\cpa",
    "cpaConfig": "D:\\old\\cpa\\config.yaml",
    "managerRuntime": "D:\\old\\manager-plus",
    "managerData": "D:\\old\\manager-data",
    "legacyStartScript": "D:\\old\\Start-CPA.ps1"
  },
  "secretsInputPath": "C:\\Users\\user\\cpa-secrets.json",
  "ports": {
    "cpa": 22117,
    "manager": 28317
  }
}
```

规则：

- `sourceMode` 只能为 `Auto` 或 `Explicit`；显式模式要求四个 runtime/config/data 路径完整。
- `legacyStartScript` 与 `secretsInputPath` 至少提供一个；优先使用明确的 secrets 文件。
- secrets 文件分别包含非空的 `cpaClientApiKey`、`cpaManagementKey`、`managerAdminKey`。不要输出或复制这些值到 request、结果、日志或对话。
- `ports` 可省略；提供时必须是两个不同的有效 TCP 端口，并与用户期望的正式配置一致。候选端口不在 request 中。
- 所有路径允许空格与非 ASCII，但必须通过 managed root 与来源安全检查。
- 删除本次临时创建的 request；不要删除用户提供的 secrets 文件或 legacy 来源。
