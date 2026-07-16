# 安全策略

## 支持版本

安全修复只面向最新已发布的小版本。

## 报告漏洞

仓库启用 GitHub Private Vulnerability Reporting 后，请优先私下提交；否则使用维护者 GitHub 主页提供的私密联系方式。

禁止在公开 Issue 中上传：

- API key、token、代理密码或环境变量 dump；
- `data.key`、SQLite、auth 文件或完整 CPA 配置；
- 原始请求/响应日志或 management page；
- 与复现无关的用户名和私有目录布局。

请提供 updater 版本、Windows/PowerShell 版本、脱敏路径、组件版本与 hash、执行命令、结构化检查项和脱敏错误。

## 安全假设

工具假设当前 Windows 账户可信，并把本机 Administrators 视为系统管理边界。跨会话锁只协调同一 Windows 账户；不要由多个 Windows 账户同时管理同一个 root。目标必须是本地 ACL-capable 文件系统，不支持共享网络存储。
