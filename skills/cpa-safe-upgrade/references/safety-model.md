# 安全模型补充

## 信任边界

只信任：

- 两个硬编码的官方 GitHub 上游仓库；
- 通过 HTTPS 获取、且 SHA256 与上游 checksum 一致的 release；
- owner、ACL、instanceId 和关键文件 hash 均通过检查的 managed root；
- executable path 与发现或记录 runtime 一致的正式端口 owner；
- bundled SQLite online-backup helper 生成并验证的快照。

目录名像 CPA、进程占用了预期端口、文件以前测试过，都不能单独构成信任证据。禁止输出进程完整命令行，因为真实参数可能包含 token。

CPA `auth` 与可选 `plugins` 代码树是递归信任边界：根、子目录和文件都不得为 reparse point，owner 必须是当前用户，ACL 只允许当前用户、SYSTEM 和本地 Administrators。接管会原地加固；复制、候选执行、正式切换和恢复会在运行插件代码前 fail closed。

首次迁移的 legacy 源可以保留普通用户只读/执行权限，但 runtime/config/auth/plugins 及父链不得允许非受信主体修改或替换内容。候选退出后生成包含相对路径、类型、长度与 SHA256 的 target runtime manifest；受保护 journal 固定其 digest、config hash 和 host。non-in-place 正式切换只启动该已测快照，不会再次复制在线 legacy config、auth 或 plugins。

## 事务边界

有状态命令在同一 Windows 账户下持有跨会话文件锁。破坏性动作前先写不含 secret、且绑定 instanceId 的 pending journal。

正式切换采用可恢复的两阶段提交：先保留 old 快照并验证 new runtime，再原子写 `current.json`，最后把 old 快照提升为 last-known-good 并删除 journal。硬中断恢复只接受两种确定状态：

- `recorded=old`：从已验证备份幂等重铺完整旧 runtime；Manager 同时重铺 SQLite 与 `data.key`；
- `recorded=new` 且 `active=new`：完成 last-known-good 提交。

hash 组合、instanceId 或备份校验出现歧义时必须停止，不能猜测。候选失败不触碰正式服务；正式切换失败必须在返回前恢复旧服务。

## 数据边界

managed root 只保留 current、一个 current release 和一个 last-known-good。迁移排除日志、测试数据库、历史下载、`_updates`、`_backups` 与候选目录。

Manager 验证保护 `usage_events` count/max-id/max-timestamp 水位，settings/model-price 数量不得减少。rollup/checkpoint 可合法增长。空数据库是合法状态，不能仅凭 `hasHistoricalData=false` 阻断。

## 网络边界

候选端口必须只有 `127.0.0.1` listener。检查端口全部 listener，不能只取第一条。正式服务默认 loopback；LAN 暴露需要用户明确授权。

候选与正式服务进程使用最小环境变量白名单，只保留 Windows 运行必需项和不含 userinfo/query/fragment 的代理 URL、TLS 路径；带内嵌账号口令的代理变量会被丢弃，也不会继承其他无关会话变量。loopback 只限制入站监听；经官方 release 与 hash 验证的二进制仍可通过当前网络或安全代理出站，它不是 AppContainer 或防火墙沙箱。

## Secret 边界

始终分开保存并使用：CPA client API key、CPA management key、Manager admin key。secret 只能进入本机请求 header 或 setup body，不得进入结果、journal、state、日志、测试或对话。写 journal 前还要拒绝带 userinfo/query/fragment 的 CPA base URL。
