# 更新记录

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
