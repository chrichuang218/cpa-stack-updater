# 安全模型

## 真值来源

迁移时，8317/18317 正式监听进程的 owner 是 active executable path 的最强证据。启动入口、显式参数、canonical state 和文件系统候选只作为辅助证据。证据冲突会阻断写操作。

## Managed root 信任边界

目标必须是专用的本地 NTFS/ReFS 目录。拒绝 UNC、盘符根、Windows/Program Files 子树、用户主目录本身、Git worktree 和 reparse traversal；LocalAppData 下的专用子目录允许使用。

实例 marker、`current.json`、旧 canonical 接管 journal、初始化 journal、升级 journal 和切换 journal 必须拥有同一个 `instanceId`。普通非空目录不会被重新“认领”；只有固定 canonical 布局、正式进程、记录 hash 和无其他 pending 全部匹配时，才允许通过可恢复的 adoption journal 接管早期版本根目录。根目录 owner 必须是当前用户，ACL 只允许当前用户、SYSTEM 和本地 Administrators；关键配置、状态、启动脚本和可执行文件也会检查 owner、ACL 与 reparse 属性。CPA `auth` 与可选 `plugins` 代码树会递归拒绝 reparse point，并对每个文件和子目录加固、校验 owner 与 ACL。

首次迁移允许 legacy 源对普通用户保留只读/执行 ACL，但 source runtime、config、auth、plugins 及其父链不得向非受信主体授予写入、修改、删除子项、改 ACL 或取得所有权的能力。CPA 候选 PID 完全退出后，工具用相对路径、类型、长度和 SHA256 生成 target runtime manifest，并把 digest、config hash 与 host 写入受保护 journal。正式切换复用这一已测试 target 快照，停服前和启动前各核对一次，不再从在线 legacy 源二次复制 config、auth 或 plugins。

写操作只允许进入固定槽位，例如 `runtime/cli-proxy-api`、`runtime/manager-plus`、`data/manager-plus`、`work/current` 和 `rollback/last-known-good`。

## Release 信任

Release 元数据与资产只从硬编码的官方 GitHub 仓库通过 HTTPS 获取。压缩包 SHA256 必须匹配 `checksums.txt`；GitHub 提供 asset digest 时也会校验。解压前检查 ZIP 条目、路径、数量和总大小。候选 exe hash 会贯穿下载、候选验证和正式切换。

上游 Windows executable 不假设拥有 Authenticode 签名。实际信任边界是上游 GitHub 仓库与已验证 release hash。

若旧 binary 的版本无法可靠识别，且 hash 与 latest stable 不同，默认阻断替换。只有用户明确承担预发布版被替换的风险后，才允许 `-AllowUnknownVersionReplacement`。

## 事务模型

升级、初始化、安装、卸载和 root 登记在同一 Windows 账户下共享跨会话独占文件锁。该锁不承诺协调另一 Windows 账户；managed root 本身只应由其 owner 运行本工具。

无密钥 pending journal 在破坏性动作前原子写入，并绑定 instance ID。runtime 切换与 `current.json` 提交是可恢复的两阶段提交：

- recorded hash 仍是 old 时，幂等重铺已验证 old runtime/Manager 数据；
- recorded hash 与 active hash 都是 new 时，完成 last-known-good 提交；
- 其他组合视为歧义并停止，不猜测恢复。

候选验证期间正式服务保持运行。只有 package、key、path、磁盘、Python、SQLite 快照和候选行为全部通过后，才进入正式停机窗口。

## Manager 数据

SQLite online backup 生成 WAL 一致快照。快照关闭全部连接后清理新生成的空 `-wal`/`-shm`；非空 WAL 不会被删除。候选兼容性要求 authoritative usage-event watermark 不变，settings 与 model-price 数量不得减少。空的合法数据库同样支持；`hasHistoricalData=false` 本身不是失败。

## 网络

候选必须只绑定 `127.0.0.1`，并检查同一端口的全部 listener，不能因第一条 listener 是 loopback 就忽略其他 LAN listener。正式服务默认 loopback；LAN 暴露必须由用户显式决定。

候选与正式服务进程使用最小环境变量白名单，只保留 Windows 运行必需项和不含 userinfo/query/fragment 的代理 URL、TLS 路径；带内嵌账号口令的代理变量会被丢弃，也不会继承其他无关会话变量。loopback 只限制入站监听；经官方 release 与 hash 验证的二进制仍可通过当前网络或安全代理出站，它不是 AppContainer 或防火墙沙箱。

## 不在范围内

- `v0.1` 不负责从零安装 CPA。
- 不自动删除 legacy 目录。
- 不静默修改防火墙。
- 不上传 telemetry、日志、配置或数据。
- 不支持任意 fork 或第三方 release 来源。
