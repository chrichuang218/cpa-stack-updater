# 参与贡献

事务与恢复逻辑的修改必须提供可重复证据，不能只靠静态阅读。

1. 保持 `skills/cpa-safe-upgrade/scripts/cpa-stack.ps1` 的公开接口小而稳定。
2. 禁止提交真实 binary、key、配置、数据库、日志或个人路径。
3. 同时运行 `powershell -File .\tools\Test-All.ps1` 与 `pwsh -File .\tools\Test-All.ps1`。
4. 每个恢复 bug 都要增加 fixture、状态真值表或 failure-injection 回归。
5. 保持“候选失败不改变正式服务”的不变量。
6. 保持“正式切换失败时，返回前恢复旧健康服务”的不变量。
7. PowerShell 源码保持 ASCII，以兼容 Windows PowerShell 5.1；中文放在 UTF-8 Markdown/YAML 中。

扩展端口、启动方式、CPU 架构、文件系统或 release 来源时，必须同步说明新的信任边界。
