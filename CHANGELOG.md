# 更新记录

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
