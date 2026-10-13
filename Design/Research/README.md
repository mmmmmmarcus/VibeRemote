# Siri Remote 麦克风研究与跨机器交接

更新：2026-10-13。应用基线 `17664de`；本目录只包含研究材料和独立诊断工具，不改变两代遥控器的运行逻辑或按钮映射。

## 接手时先读

1. [主报告](FirstGenerationMicrophoneControl.md)：按四个阶段记录源码、固件、实机 LOCK、解锁与恢复调查。最新结论见第三、第四阶段。
2. [解锁与恢复风险](FirstGenerationMicEvidence/unlock-storage-risk.md)：存在重锁代码不等于具有可靠的恢复通路。
3. [解锁入口](FirstGenerationMicEvidence/unlock-entry-and-fwu.md)与[通知来源](FirstGenerationMicEvidence/unlock-notification-entry.md)：下一步未解决的问题。
4. 仓库根目录 [AGENTS.md](../../AGENTS.md)：两代布局、映射与现有麦克风通路的约束。

## 已确认与未确认

- **特定实机结果**：第一代黑玻璃遥控器，PID `026D`、hardware `0A00`、firmware `B000750001001801300033022000040431001800C1000100`。2026-10-13 读取 Feature E1 多次返回 `E1 01`，对应持久 LOCK=1。一次固定零时长 31 请求返回通用错误；未独立抓到其空口应答，不能单凭错误码证明 LOCK 是拒绝来源。见 [API 记录](FirstGenerationMicEvidence/live-lock-probe.json)。
- **静态候选路径**：98 不能从普通连接状态单独开始收音；31 模拟 Siri 受 LOCK 限制。内部解锁函数会改持久配置。`ds set` 有重锁代码，但 CLI 的实际传输与可达性未确认。
- **未验证**：不按物理 Siri 键时持续采集新声音、软件停止、解锁与重锁的完整流程、失败后的工厂数据恢复。不要把此结论外推到另一台遥控器或二/三代。
- **当前边界**：继续只读调查；不实际解锁、不写持久配置、不刷固件、不尝试未知按键组合、不修改现有映射。之前的零时长诊断不代表已授权在新设备上重复写入。

## 换机器 / 换遥控器

先记录新机器的 macOS 版本、仓库提交，以及遥控器 PID、hardware/firmware revision、BLE 或有线传输、接口用途。名称、颜色和 209-byte report size 都不能单独确定兼容性。Lightning 充电接口不是已验证的 BLE 诊断接口。

LOCK=1 是上一只设备的测量，不是型号的常量。另一只同型号设备也应重新读取；固件不同则必须重新核对报告语义和地址，不能修改脚本里的校验值后盲用。第二/三代需要独立的固件与证据。

`live-lock-probe.json` 中的 registry entry ID 是历史记录；它会随设备重新枚举变化，不能复制到另一台机器运行。原始蓝牙地址与声音未保存在本目录。

## 本地工具

### 离线固件检查（无设备访问）

[inspect_b439_firmware.py](inspect_b439_firmware.py) 只接受已核对的 B439 v0118 hw000A production AFU 的 SHA-256。它输出音频状态机和报告注册表，并可封装供 llvm-objdump 使用的 ELF：

```sh
python3 Design/Research/inspect_b439_firmware.py /path/to/B439-remote-v0118-hw000A-prod-signed.afu
python3 Design/Research/inspect_b439_firmware.py /path/to/B439-remote-v0118-hw000A-prod-signed.afu --elf /path/to/new-analysis.elf
xcrun llvm-objdump -D --triple=thumbv7em-none-eabi --start-address=0x08023160 --stop-address=0x080231C0 /path/to/new-analysis.elf
```

ELF 仅供分析，不能加载或刷入；输出路径必须尚不存在。完整 AFU 文件偏移 0 对应 `08008000`，不要去掉头部再使用本文地址。

[firmware-provenance.json](FirstGenerationMicEvidence/firmware-provenance.json) 保存 Apple 官方 OTA 下载 URL、归档与各文件 SHA-256，可在另一台机器重新获取并校验。Git 中保留推导结果与关键反汇编，不包含完整 Apple 固件、kernelcache 或可刷写映像。

### 实机诊断工具（默认只读）

[probe_first_generation_lock.py](probe_first_generation_lock.py) 使用 macOS IOKit，默认仅调用 Feature GET E1。它核对 PID/hardware/完整 firmware revision、BLE 传输和 `FF00/000B` 接口；不匹配会停止。`--report 0xff` 是对照读取。

VibeRemote 通常独占 HID，工具不能抢占其句柄。确需实机读取时，调用方必须安排短暂退出应用、进程超时和 finally 恢复应用；退出也会停止应用管理的 PacketLogger，因此默认测试没有独立空口证据。脚本本身不会自动退出应用或恢复 Bridge。

工具保留 `--zero-duration` 以复核上一轮实验：仅在确认 E1=1 后发送一次固定的 31 零时长请求。**这是写操作，本轮交接不要求运行它。** 工具没有解锁、任意 payload 或真实麦克风启动功能。

## Git 中的证据

- `audio-tables.json`：离线音频状态机/报告表。
- `unlock-fwu-transitions.json`：固件更新状态机。
- `lock-read-and-ack.md`：E1 与 DSM LOCK、蓝牙完成应答路径。
- `firmware-paths.md`：第二阶段的历史静态快照，后续实机结果以主报告为准。
- `driver-provenance.json`：本机 AppleBluetoothRemote 的身份、哈希、提取说明；其 Preboot 路径与地址属于旧机器，不能直接套用。
- `disassembly/`：关键函数反汇编摘录及哈希清单，覆盖 LOCK 读取、解锁入口和 macOS PushToTalk/Feature 发送路径。反汇编中的 literal pool 可能被显示成指令，应按报告中的函数边界解读。

机器上的临时目录不是后续工作所需的唯一证据来源；本索引、报告、摘录和官方源文件校验信息均随 Git 保存。存储分析中未保存摘录的地址可由同一 AFU 与 ELF 工具重新生成。

## 下一步只读调查

1. 追踪 CLI 输入对象 `20000898` 的实际传输，确认重新上锁入口是否能够由主机访问。
2. 查清 BIR event 1 的产生条件；不要把内部事件编号当成可发送的 HID 命令或已知按键手势。
3. 在考虑任何解锁实验前，建立可验证的工厂数据备份/恢复与重锁通路。目前双 bank 设计不能替代恢复验证。
4. 如以后获得可用的软件控制入口，再独立验证新声音、明确停止和映射隔离；保留两代原有物理 Siri 使用方式。
