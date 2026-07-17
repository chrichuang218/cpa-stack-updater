# 安全模型补充

## 信任边界

只信任：

- 两个硬编码的官方 GitHub 上游仓库；
- 通过 HTTPS 获取、且 SHA256 与上游 checksum 一致的 release；
- updater 自更新只接受固定官方仓库中版本更高的稳定 Release，并同时验证版本化 ZIP、`checksums.txt`、GitHub 双 digest 与包内 VERSION；
- owner、ACL、instanceId 和关键文件 hash 均通过检查的 managed root；
- executable path 与发现或记录 runtime 一致的正式端口 owner；
- bundled SQLite online-backup helper 生成并验证的快照。

目录名像 CPA、进程占用了预期端口、文件以前测试过，都不能单独构成信任证据。禁止输出进程完整命令行，因为真实参数可能包含 token。

CPA `auth`、可选 `plugins` 代码树和 Manager data tree 是递归信任边界：根、子目录和文件都不得为 reparse point，ACL 只允许当前用户、SYSTEM 和本地 Administrators。根与稳定文件 owner 必须是当前用户；Manager 运行期新建并继承安全 ACL 的 WAL/SHM 后代只允许受信 owner。接管会原地加固；复制、候选执行、正式切换和恢复会在运行代码或读取 SQLite sidecar 前 fail closed。

普通非空目录不能被认领。installer 只可对用户明确指定、ACL 已保护且完全为空的 root 写入带 bootstrap hash 的 preinitialized instance marker；此状态只允许固定 launcher，直到一键 `upgrade` 的自动迁移建立同 instance 的 `current.json`。任何额外内容、marker 漂移或 launcher hash/ACL 漂移都会阻断。

首次迁移的 legacy 源可以保留普通用户只读/执行权限，但 runtime/config/auth/plugins 及父链不得允许非受信主体修改或替换内容。候选退出后生成包含相对路径、类型、长度与 SHA256 的 target runtime manifest；受保护 journal 固定其 digest、config hash 和 host。non-in-place 正式切换只启动该已测快照，不会再次复制在线 legacy config、auth 或 plugins。

所有目标树、JSON 临时文件和目录交换后缀必须满足 Windows PowerShell 5.1 兼容预算：目录 247 字符、文件 259 字符。初始化和升级在停止正式服务或禁用 collector 前完成预检。

## 事务边界

有状态命令在同一 Windows 账户下持有跨会话文件锁。破坏性动作前先写不含 secret、且绑定 instanceId 的 pending journal。公开 `recover` 只分派到 recovery-only interface；并发调用即使在等待锁期间 journal 已被另一调用收敛，也不能开始新迁移、联网升级或 LAN 变更。初始化/升级的顶层 journal 可以拥有经底层再次验证的 switch journal 与 `rollback/pending-*` 从属 artifact；多个无关顶层事务仍必须阻断。

公开 `upgrade` 在 runtime 事务前先检查 updater。发现新版时只运行安全下载到本地且通过上述校验的 installer，原子提交后用新版 CLI 重执行一次；查询、校验、安装或重执行失败不接触 runtime。源码分支、fork、预发布版和管道执行不受支持。

正式切换采用可恢复的两阶段提交：先保留 old 快照并验证 new runtime，再原子写 `current.json`，最后把 old 快照提升为 last-known-good 并删除 journal。硬中断恢复只接受两种确定状态：

- `recorded=old`：从已验证备份幂等重铺完整旧 runtime；Manager 同时重铺 SQLite 与 `data.key`；
- `recorded=new` 且 `active=new`：完成 last-known-good 提交。

hash 组合、instanceId 或备份校验出现歧义时必须停止，不能猜测。候选失败不触碰正式服务；正式切换失败必须在返回前恢复旧服务。

LAN 变更在写两份配置前记录 canonical root、instance、`current.json` hash、before/target config hash 和受保护备份 hash。新监听和完整健康状态必须在 journal 仍存在时验证，删除 journal 才算 commit。硬中断恢复只覆盖仍等于 before/target 的配置；未知修改不覆盖。即使配置文本已经匹配，`NoChange` 也必须验证真实 listener 与健康状态。

停止候选或正式服务前，先固定已验证 listener 的 `Process` 与 OS handle。即使 listener 在停服函数进入前或等待期间消失，也只终止并等待该固定进程；updater 启动但从未监听的游离候选按其 `Process` 对象清理。固定进程退出、端口释放和 executable 可独占打开必须同时成立；新 PID/path 抢占端口时立即失败且绝不终止新 owner。切换或回滚复制关键文件后，必须在重启前恢复 runtime 父目录、关键文件和 Manager data tree 的 owner 与 ACL。

## 数据边界

managed root 只保留 current、一个 current release 和一个 last-known-good。迁移排除日志、测试数据库、历史下载、`_updates`、`_backups` 与候选目录。

Manager online backup 必须可生成、可重新打开并通过 `quick_check`。验证保护必需业务表和 `usage_events` count/max-id/max-timestamp 水位，升级前存在的 settings/model-price 数据不得减少。exe 与 `data.key` hash 仍严格校验；SQLite 文件 SHA256、大小、页布局、WAL/SHM、checkpoint 和可重建 rollup 不要求绝对一致。空数据库是合法状态，不能仅凭 `hasHistoricalData=false` 阻断。

## 网络边界

候选端口必须只有 `127.0.0.1` listener。检查端口全部 listener，不能只取第一条。正式服务默认 loopback；LAN 暴露需要用户明确授权。

候选与正式服务进程使用最小环境变量白名单，只保留 Windows 运行必需项和不含 userinfo/query/fragment 的代理 URL、TLS 路径；带内嵌账号口令的代理变量会被丢弃，也不会继承其他无关会话变量。loopback 只限制入站监听；经官方 release 与 hash 验证的二进制仍可通过当前网络或安全代理出站，它不是 AppContainer 或防火墙沙箱。

长驻进程通过 Windows handle-list 白名单以无控制台窗口方式启动，只继承三个指向 `NUL` 的 stdin/stdout/stderr。父 PowerShell 的输出管道、文件和 secret 句柄不得传入服务，CLI 返回也不得依赖长驻服务退出。canonical 快捷方式只保留一个可见且 `-NoExit` 的 PowerShell，并在同一进程直接运行 Fast starter；Fast 不执行事务级 ACL、hash、state 或健康门禁，完整检查保留在 CLI `start`、迁移、恢复与升级路径。

## Secret 边界

始终分开保存并使用：CPA client API key、CPA management key、Manager admin key。secret 只能进入本机请求 header 或 setup body，不得进入结果、journal、state、日志、测试或对话。写 journal 前还要拒绝带 userinfo/query/fragment 的 CPA base URL。
