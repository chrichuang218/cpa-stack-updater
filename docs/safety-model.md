# 安全模型

## 真值来源

迁移时，managed stack 配置或显式 request 所指正式监听进程的 owner 是 active executable path 的最强证据。启动入口、canonical state 和文件系统候选只作为辅助证据。证据冲突会阻断写操作；不把任何固定端口当作普遍真值。

## Managed root 信任边界

目标必须是专用的本地 NTFS/ReFS 目录。拒绝 UNC、盘符根、Windows/Program Files 子树、用户主目录本身、Git worktree 和 reparse traversal；LocalAppData 下的专用子目录允许使用。

实例 marker、`current.json`、旧 canonical 接管 journal、初始化 journal、升级 journal 和切换 journal 必须拥有同一个 `instanceId`。普通非空目录不会被重新“认领”；唯一的未迁移例外是 installer 对用户明确指定、ACL 已保护且完全为空的 root 写入带 bootstrap hash 的 preinitialized marker，随后只允许固定 launcher，直到显式迁移建立 `current.json`。已有早期 canonical root 只有在固定布局、正式进程、记录 hash 和无其他 pending 全部匹配时，才允许通过可恢复的 adoption journal 接管。根目录 owner 必须是当前用户，ACL 只允许当前用户、SYSTEM 和本地 Administrators；关键配置、状态、启动脚本、可执行文件及其直接 runtime/data 父目录也会检查 owner、ACL 与 reparse 属性。CPA `auth`、可选 `plugins` 代码树和整个 Manager data tree 会递归拒绝 reparse point，并校验每个文件和子目录的 owner 与 ACL。Manager 运行期新建的 WAL/SHM 可以安全继承已保护 data root 的 ACL；其 owner 仍只能是当前用户、SYSTEM 或本地 Administrators。

首次迁移允许 legacy 源对普通用户保留只读/执行 ACL，但 CPA 与 Manager 的 source runtime/data、config、auth、plugins 及其父链不得向非受信主体授予写入、修改、删除子项、改 ACL 或取得所有权的能力。CPA 候选 PID 完全退出后，工具用相对路径、类型、长度和 SHA256 生成 target runtime manifest，并把 digest、config hash 与 host 写入受保护 journal。正式切换复用这一已测试 target 快照，停服前和启动前各核对一次，不再从在线 legacy 源二次复制 config、auth 或 plugins。

写操作只允许进入固定槽位，例如 `runtime/cli-proxy-api`、`runtime/manager-plus`、`data/manager-plus`、`work/current` 和 `rollback/last-known-good`。

所有投影目录、文件、JSON 临时后缀和目录交换后缀都必须满足 Windows PowerShell 5.1 的兼容预算：目录不超过 247 字符，文件不超过 259 字符。初始化和升级会在停止第一个正式服务或禁用 Manager collector 前完成预检；超限时不进入停机窗口。

## Release 信任

Release 元数据与资产只从硬编码的官方 GitHub 仓库通过 HTTPS 获取。CPA/Manager 压缩包 SHA256 必须匹配 `checksums.txt`；GitHub 提供 asset digest 时也会校验。解压前检查 ZIP 条目、路径、数量和总大小。候选 exe hash 会贯穿下载、候选验证和正式切换。

上游 Windows executable 不假设拥有 Authenticode 签名。实际信任边界是上游 GitHub 仓库与已验证 release hash。

若旧 binary 的版本或来源无法可靠识别，公开 `upgrade` 自动允许用已验证的 latest stable 替换。该策略只放宽版本单调性证明；官方 release、checksum、候选健康、SQLite 水位、进程身份与自动回滚门禁保持不变。

只有公开 `upgrade` 可以在线更新 updater/Skill，来源固定为 `chrichuang218/cpa-stack-updater` 的最新非预发布 Release。远端版本必须高于本地，并且固定名称 ZIP、`checksums.txt`、两项 GitHub SHA256 digest、Release tag、仓库 VERSION 与 Skill VERSION 必须一致；安全解压后才运行本地 `install.ps1`。安装使用 ownership marker、双槽和受保护 journal 原子提交，成功后旧进程只负责启动新版 CLI 一次。查询、校验、安装或重执行失败全部 fail closed，不接触 runtime。源码分支、fork、预发布版和远程管道执行永远不受支持。用户明确提供的可信本地发行目录仍可作为手工/离线更新入口。

## 事务模型

迁移、恢复、升级、安装、卸载和 root 登记在同一 Windows 账户下共享跨会话独占文件锁。`upgrade` 先收敛一次 updater 自更新或新版重执行，再按固定上限编排一次 recover、一次 migrate、一次 runtime upgrade，并在成功后幂等维护默认桌面快捷方式；每个底层事务仍保持独立结果与失败边界。快捷方式失败只追加 warning，不回滚已提交的运行时升级。该锁不承诺协调另一 Windows 账户；managed root 本身只应由其 owner 运行本工具。

无密钥 pending journal 在破坏性动作前原子写入，并绑定 instance ID。`recover` 只调用底层 recovery-only interface；即使并发恢复时 journal 已被另一调用收敛，也不会开始新迁移、联网升级或 LAN 变更。初始化或升级的顶层 journal 可以拥有经过底层再次校验的 switch journal 与 `rollback/pending-*` 从属 artifact；无关的多个顶层事务仍视为歧义。runtime 切换与 `current.json` 提交是可恢复的两阶段提交：

- recorded hash 仍是 old 时，幂等重铺已验证 old runtime/Manager 数据；
- recorded hash 与 active hash 都是 new 时，完成 last-known-good 提交；
- 其他组合视为歧义并停止，不猜测恢复。

候选验证期间正式服务保持运行。只有 package、key、path、磁盘、Python、SQLite 快照和候选行为全部通过后，才进入正式停机窗口。

LAN 配置也是 write-ahead 事务：journal 绑定 canonical root、instance、`current.json`、两份配置的 before/target hash，以及受保护备份的 hash。新监听状态与完整健康契约在 journal 仍存在时验证；删除 journal 是唯一 commit point。硬中断后 `recover` 只接受活动配置仍等于 before/target 之一，并恢复、重启和验证旧状态；未知修改不会被覆盖。

停止候选或正式服务前，工具先从已验证 listener 固定 `Process` 对象和 OS handle。即使 listener 在停服函数进入前或等待期间消失，仍只终止并等待该固定进程；updater 已启动但从未绑定端口的游离候选也按其 `Process` 对象清理。完成条件是固定进程退出、端口释放且 executable 可独占打开；若端口被新 PID/path 抢占则立即停止，绝不终止新 owner。切换或恢复复制关键文件后，会在重新启动前恢复 runtime 父目录、关键文件和 Manager data tree 的 owner 与 ACL。

## Manager 数据

SQLite online backup 必须成功生成、重新打开并通过 `quick_check`。候选兼容性和回滚只保护必需业务表，以及 `usage_events` 的 count/max-id/max-timestamp 水位；升级前存在的 settings 与 model-price 数据不得减少。exe 与 `data.key` 继续使用 hash 校验。数据库文件 SHA256、大小、页布局、WAL/SHM、checkpoint 和可重建 rollup 不要求绝对一致。空的合法数据库同样支持；`hasHistoricalData=false` 本身不是失败。

## 网络

候选使用动态分配、未占用的高位端口，必须只绑定 `127.0.0.1`，并检查同一端口的全部 listener，不能因第一条 listener 是 loopback 就忽略其他 LAN listener。候选端口不属于公开接口或固定配置。正式服务默认 loopback；LAN 暴露是独立事务，必须由用户显式决定。LAN 的 `NoChange` 也必须验证实际 listener 与完整健康状态，不能只比较配置文本。

候选与正式服务进程使用最小环境变量白名单，只保留 Windows 运行必需项和不含 userinfo/query/fragment 的代理 URL、TLS 路径；带内嵌账号口令的代理变量会被丢弃，也不会继承其他无关会话变量。loopback 只限制入站监听；经官方 release 与 hash 验证的二进制仍可通过当前网络或安全代理出站，它不是 AppContainer 或防火墙沙箱。

长驻进程通过 Windows handle-list 白名单以无控制台窗口方式启动，只继承三个指向 `NUL` 的 stdin/stdout/stderr；父 PowerShell 的管道、文件和 secret 句柄不会传入服务。canonical 桌面快捷方式只保留一个可见且 `-NoExit` 的 PowerShell，并在同一进程直接运行 Fast starter；Fast 只按配置路径复用或拉起进程，不执行事务级 ACL、hash、state 或健康门禁。完整门禁继续由 CLI `start`、迁移、恢复与升级负责。后台 CPA/Manager 进程仍保持无控制台，CLI 的结构化结果不依赖长驻服务退出。

## 不在范围内

- `v0.2` 不负责从零安装 CPA。
- 不自动删除 legacy 目录。
- 不静默修改防火墙。
- 不上传 telemetry、日志、配置或数据。
- 不支持任意 fork 或第三方 release 来源。
