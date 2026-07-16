# 更新记录

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
