# 更新记录

## 1.1.2 - 2026-07-21

- 明确 Windows 定时任务必须把 `-NonInteractive` 作为 PowerShell 宿主参数放在 `-File` 前，避免脚本参数绑定失败导致自动升级未执行。
- 增加定时升级命令契约回归测试，锁定无人值守调用的参数顺序。

## 1.1.1 - 2026-07-18

- 修复迁移与运行时升级把 canonical 快速 bootstrap 覆盖成完整 starter 的回归；桌面快捷方式继续显式进入 `Fast` 模式，不再意外执行完整启动检查。
- launcher 同步统一渲染 installer 的 canonical bootstrap，已发生覆盖的托管实例会在下一次更新时自动恢复快速启动。

## 1.1.0 - 2026-07-18

- `upgrade` 在接触 CPA/Manager runtime 前自动检查固定官方仓库的 updater Release；发现更高稳定版本时校验固定资产名、`checksums.txt` 与 GitHub SHA256 digest，通过本地 installer 原子更新 Skill，再使用新版 CLI 重新执行一次升级。
- updater 检查、下载、校验、安装或新版重执行失败时返回 `automation.failedStep=updater` 并停止，不继续使用旧 updater；状态、启动、快捷方式和 LAN 操作不触发联网自更新。
- 标签 CI 在完整测试通过后生成最小版本化 ZIP 与 `checksums.txt`，并发布为 GitHub Release 资产，为无人值守定时升级提供可验证的自更新信任链。

## 1.0.9 - 2026-07-17

- 主 `SKILL.md` 移除 0.x 历史兼容说明，新用户直接进入当前执行流程；仅在实际检测到旧 updater 残留时按需读取故障排查规则。

## 1.0.8 - 2026-07-17

- 删除已无人读取的快速启动临时进度文件通道，实时状态继续直接显示在唯一的 PowerShell 7 窗口中。
- 删除 `doctor`、`plan`、`init`、`register-root` 旧命令及其公开兼容参数；公共 CLI 仅保留正式 v2 操作，自动升级和内部恢复安全门禁保持不变。

## 1.0.7 - 2026-07-17

- 桌面快速启动与安全事务彻底分流：canonical bootstrap 在当前 PS7 窗口直接调用 bundled starter 的 `Fast` 模式，不再执行 `cpa-stack status/start`、ACL、hash、端口健康或 Manager readiness 预检，也不再创建第二个 PowerShell 进程。
- Fast 模式仅按已配置 executable 复用现有进程，缺失时直接用原有无控制台进程启动器拉起 CPA/Manager，并立即打开管理页面；完整检查继续保留在 CLI `start`、迁移、恢复与升级路径。
- 已运行栈的桌面启动实测由约 15.1 秒降至约 2.7 秒，剩余主要是 WindowsApps PowerShell 7 冷启动时间。

## 1.0.6 - 2026-07-17

- 桌面快速启动和隐藏 CLI 子进程优先使用 PowerShell 7 (`pwsh.exe`)；未安装 PS7 时自动回退 Windows PowerShell 5.1，快捷方式契约升级为 v3 并自动修复现有入口。

## 1.0.5 - 2026-07-17

- 修复桌面快速启动时内部 PowerShell 子进程导致终端窗口反复闪烁的问题：交互入口改为显式隐藏并重定向输出的子进程，内部状态检查与启动脚本不再抢占桌面窗口，也避免 `Start-Job` 的冷启动延迟。
- 新增协议安全的实时进度通道，配置校验、CPA API、Manager 与浏览器阶段在执行过程中立即显示，不再等全部完成后才一次性输出。

## 1.0.4 - 2026-07-17

- 运行时升级成功后自动创建或更新当前用户桌面的 `CPA 本地启动.lnk`；可识别旧 CPA 快捷方式会先备份再接管，旧的“（新版）”名称在新入口成功建立后自动清理，不再要求二次确认，未知无关冲突仍拒绝覆盖。
- 桌面快速启动改为可见并保留的 PowerShell 窗口，使用内置 CPA 图标、标题、颜色与分阶段状态提示；独立的“创建桌面启动方式”请求直接执行同一幂等 Ensure。
- 快捷方式维护失败以 warning 返回，不回滚已经成功的 CPA/Manager 运行时升级。

## 1.0.3 - 2026-07-17

- `upgrade` 成为单命令自动事务：遇到单一 pending 时自动恢复一次，尚未建立 canonical stack 时自动迁移一次，随后自动升级；`-RequestPath` 可直接随 upgrade 提供，所有重试有固定上限。
- 升级授权同时覆盖必要的 recover、migrate 与未知版本稳定版替换，不再要求中途二次确认；不可证明的 journal、进程、ACL、checksum、候选健康或 SQLite 数据问题仍立即失败。

## 1.0.2 - 2026-07-17

- 自动升级默认允许用已验证的 latest stable 替换无法可靠识别版本或来源的旧 binary，不再要求 `-AllowUnknownVersionReplacement` 二次确认；官方 release、checksum、候选健康、SQLite 水位与自动回滚门禁保持不变。

## 1.0.1 - 2026-07-17

- 修复管理员令牌下首次迁移成功后，`ops`、`state`、`runtime`、`data` 和 canonical launcher 仍由 Administrators 持有，导致下一次 `status/upgrade` 被自身健康门禁拒绝的问题。
- 初始化时统一加固全部 canonical 顶层目录、launcher 与 `config\stack.psd1`；中断恢复启动前也会修复由 updater 写出的 stack config owner/ACL。
- 修复状态页把缺少组件可选字段的合法 pending journal 误报为 `unreadable`，并允许公开 `recover` 在当前 hash、instance、路径和成功 switch 结果全部匹配时清理已提交的孤立 `.previous` journal。
- 已用 CPA v7.2.80 / Manager v1.11.1 在隔离 managed root 完成真实升级：测试端口升至 v7.2.81 / v1.11.2，SQLite 历史水位、`data.key`、last-known-good 与正式栈均保持正确。
- 测试框架识别企业端点策略锁定 PowerShell WSH 探针的环境，并按实测耗时为完整事务集成测试提供独立 45 分钟上限。

## 1.0.0 - 2026-07-17

- 首个受支持的正式版本。`0.x` 仅视为开发过程产物，不承诺旧 updater 安装、journal 或事务状态兼容；从本版本开始建立稳定升级基线。
- 修复管理员令牌默认 owner 为 `BUILTIN\Administrators` 时，原子 JSON 写入会导致 `current.json` 与 pending journal 被自身安全检查拒绝的问题；写入与替换后统一恢复当前用户 owner 和受保护 ACL。
- CPA `auth` 根继续严格保护，运行期日志后代允许继承仅包含当前用户、SYSTEM 与 Administrators 的受信 ACL；`plugins` 仍保持全树严格校验。
- CPA 与 Manager 回滚快照进入 pending 前整树加固，确保正式切换中断后恢复器可以读取、验证并自动收敛。
- 已用真实动态 loopback 候选端口完成 CPA v7.2.81 与 Manager Plus v1.11.2 升级验证，并核对 SQLite 历史水位、`data.key` 与 collector 状态。

以下 `0.x` 条目仅保留为开发历史，不属于受支持版本。

## 0.2.0 - 2026-07-17

- 将公开 CLI 重构为 schema v2 深模块：`status`、`recover`、`migrate`、`upgrade`、`start`、`shortcut` 与 `lan` 各自拥有显式事务；升级不再隐式迁移、恢复、修改快捷方式或改变 LAN。`plan`、`doctor`、`init` 与 `register-root` 仅保留一版兼容映射。
- 候选验证改为动态分配未占用的高位 loopback 端口，并把正式端口贯穿配置、journal、切换与恢复。测试引入 Production Guard、隔离 root/state/lock 与 `KILL_ON_JOB_CLOSE`，正式 listener、PID、控制文件、exe hash 和关键 ACL 变化会阻断发布。
- 新增 `install.ps1 -Action Check|Update`：Check 严格零写入，Update 使用双槽、锁内重算和受保护 write-ahead journal，支持并发幂等与 hard-kill 恢复；launcher 或 root registration 未完成时返回可重试失败，不伪报成功。显式空 StackRoot 会写受保护 preinitialized marker，稳定 bootstrap 可定位自定义 CodexHome；Skill 只允许从用户提供的可信本地发行目录更新，不在线替换自身。
- 新增托管桌面快捷方式事务，支持 `Absent/Matching/Drifted/Adoptable/Conflict`、显式接管、原子提交和零写入复检；新增独立 LAN write-ahead 事务、失败自动回滚及 hard-kill 后的公开恢复。
- ACL 加固只读写 Owner/Group/DACL，不再 round-trip SACL；重复保护保持零写入，并把 runtime/data 的关键直接父目录纳入信任边界。
- 精简 `SKILL.md` 为授权与编排层，迁移请求、安全模型和故障排查按需加载；共享 StateInspection seam 阻止状态错误伪成功或继续写入，Result seam 统一错误对象与协议失败，所有主流程在 Windows PowerShell 5.1、PowerShell 7 和隔离真实进程事务测试中验证。

## 0.1.4 - 2026-07-16

- 修复两阶段正式切换在提交 `current.json` 前用旧 hash 执行稳态健康检查、从而必然误判新 runtime 不健康的问题。过渡期检查现在只接受绑定当前 instance、路径和 old/new hash 的 `runtime-verified` switch journal；CPA 与 Manager 均通过正式健康探测后才提交新状态，真实失败仍按旧状态自动回滚。

## 0.1.3 - 2026-07-16

- 修复已登记 canonical root 位于普通开发目录时无法更新 Skill 的问题。canonical 更新继续逐项校验 root、state、launcher 的 owner/ACL 与 reparse 属性，不再把 root 之外的父目录 ACL 当作安装门禁；legacy 迁移来源的祖先检查保持不变。

## 0.1.2 - 2026-07-16

- 修复长驻 CPA/Manager 继承嵌套 PowerShell 输出管道的问题；托管进程以无控制台窗口方式启动，且只继承指向 Windows `NUL` 的 stdin/stdout/stderr，升级结果不再等待正式服务退出才返回。
- 停服前固定已验证 listener 的 `Process` 对象；即使 listener 提前消失，仍会终止并等待同一进程、端口和 executable 文件锁全部释放。updater 已启动但尚未监听的游离候选也按固定进程清理，端口被新 owner 抢占时拒绝继续且不误杀。
- Manager 候选验证和非原地回滚改为业务语义校验：online backup 必须可生成、可重新打开并通过 `quick_check`，`usage_events` 三项水位与升级前存在的关键业务表不得回退；不再要求 SQLite 文件 SHA256、大小、页布局、WAL/SHM、checkpoint 或 rollup 绝对一致。exe 与 `data.key` hash 仍严格校验。
- 增加 Windows PowerShell 5.1 兼容路径预算：目录最长 247 字符、文件最长 259 字符，并在停止正式服务或禁用 collector 前校验所有投影路径和事务后缀。
- 正式切换与自动回滚会重新加固 runtime 父目录和整个 Manager data tree（含 WAL/SHM）；非原地回滚在执行旧 Manager 前复核父链 ACL、exe、`data.key` 与 SQLite 水位。无 pending 时，升级还可在 hash、监听路径与 PID 全部匹配后修复已记录 executable 的 ACL 漂移。
- 增加 PS5.1/PS7 进程生命周期回归，覆盖嵌套输出捕获、长驻进程存活、listener 消失但 PID 未退出，以及 standalone canonical launcher 的同等隔离。
- 获准刷新的 canonical 桌面快捷方式默认用 `powershell.exe -NonInteractive -WindowStyle Hidden` 启动，并对 target、参数、工作目录和 WSH window style 做统一写入与恢复校验。直接 CLI 保留调用方终端，内部 PowerShell 复用同一控制台，不另弹窗口。

## 0.1.1 - 2026-07-16

- 修复编辑器或终端占用已安装 Skill 时的更新事务：有限重试后给出明确提示，不结束用户进程。
- 旧 Skill 成功移入事务槽后才写 ownership marker；失败会恢复原 `installed` 与已有 `previous`，不留下假拥有标记或丢失回滚槽。
- adopted root 会在 swap 前校验自身与父链 ACL；Skill core commit 后的 launcher、locator 和旧槽清理失败改为结构化 warning，不再回滚成新旧混合状态。
- 重跑安装会在 swap 前安全收敛遗留的 owned `staging-*` / `retained-*`，包括最终删除失败留下的空固定槽；卸载会先无路径变更地检查全部目标是否可删除，锁冲突时不删除任何 owned 目录。
- 安装、adoption、路径与启动恢复测试改用独立 LocalAppData fixture，不再读写真实 root locator 或 operation lock，并增加中途失败后的双槽恢复回归。

## 0.1.0 - 2026-07-16

- 将 CPA 迁移与升级流程抽成独立开源项目。
- 支持任意现有本地盘、空格与中文路径，并登记 canonical root。
- 人与 Codex Skill 共用一个稳定 CLI。
- 增加 owner/ACL、instanceId、reparse、安装所有权和 secret 输出防护。
- 增加官方 release checksum、安全解压、候选 hash 固定与全 listener loopback 校验。
- 增加 SQLite online backup、sidecar 清理、空数据库兼容和两阶段硬中断恢复。
- 增加旧 canonical root 的 journal 化原地接管、legacy 源可变权限门禁、ACL 与 auth/plugins tree 递归加固。
- 首次迁移用候选退出后的 runtime manifest、config hash 和 host 绑定正式快照，避免停服后从在线 legacy 源重新取数。
- 增加逐跳 HTTPS 下载校验、流式大小上限、trusted-listener 密钥门禁和最小进程环境。
- 增加稳定 installed CLI、版本化 JSON、原子 installer/self-uninstaller 与 launcher 同步。
- 增加中文文档、PS5/PS7/Python 测试、真实事务 failure-injection 与 Windows tag CI。
