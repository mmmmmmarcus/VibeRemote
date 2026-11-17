# 2026-10-13 接手：当前 0314 / 0021 / 0060 遥控器

## 结论与操作边界

**当前机器连接的是另一只第二代遥控器，LOCK 尚未测得。** 不能沿用历史
026D / 0A00 / v0118 的 `E1 01` 结果，也不能运行第一代诊断脚本。
本轮只有系统设备枚举、下载官方固件和离线静态分析；研究工具没有打开 HID、
发送报告、退出应用、尝试按键组合或执行解锁、重锁、重启、配对、刷写。
应用本来就在运行，其日常 keepalive 不属于本轮发起的诊断。
没有更改偏好、安全设置或任何一代按钮映射。

发现与当前属性匹配的 Apple 生产固件，并定位到 LOCK 读取候选分支；但内部
报告号至 BLE HID 请求的注册、封装及转换尚未闭环，因而没有把候选编号发到设备。
这不是 API 读取失败，也不是 LOCK=0 或 LOCK=1，更不是软件解锁命令可执行。

## 仓库准备（实机观察）

初始 `git status --porcelain=v1` 为空，没有需要暂存的用户修改。
`git fetch origin` 成功；本地 main 与 origin/main 均为
`8bfe7b7e632b0f75d545371b9316b45638ddc793`，祖先检查通过。
阅读 AGENTS.md、研究索引、主报告第三/第四阶段及关联证据后开始检查。
本轮新增内容留在工作区，没有提交或推送。

## 当前设备身份（实机观察）

机器系统为 macOS 27.0.1 / 26A434。IORegistry 的完整 HID 枚举与
`system_profiler SPBluetoothDataType -json` 的 connected 区域一致：
只有一只连接中的 Siri Remote，七个接口拥有同一物理蓝牙标识。
本轮唯一目标就是这只设备；名称和 209 字节报告尺寸没有被用于代际判定。

| 项目 | 历史机器/遥控器 | 当前机器/遥控器 |
|---|---|---|
| 布局/代际 | 第一代黑玻璃 | 第二代铝制，按 PID 与硬件/固件组合判定；未现场目视验外观 |
| Vendor / Product | Apple / 026D | 004C / 0314 |
| 硬件属性原文 | `0A00` | `0x0021`（33） |
| 完整固件属性原文 | `B000750001001801300033022000040431001800C1000100` | `0x0060`（96）；这是系统提供的完整属性，不是截短旧格式 |
| 传输 | 历史 BLE 诊断 | `Bluetooth Low Energy` |
| LOCK 实机结果 | E1 GET 返回 `E1 01` | **未读，未知** |
| 对应静态固件 | B439 v0118 hw000A | p0x314 v00060 hw0033 |

当前 IORegistry 未出现遥控器 USB/Lightning 接口；没有把充电接口当输入设备。
七个 PrimaryUsagePage / PrimaryUsage 如下。用途取 HID collection 声明，
不表示所有接口均向第三方应用交付数据。

| Page / Usage | 用途 |
|---|---|
| 000D / 0001 | Digitizer collection |
| 000C / 0109 | Consumer collection，0109 |
| FF00 / 000B | Apple vendor management collection |
| 000C / 0001 | Consumer Control |
| 000C / 0004 | Microphone/audio collection |
| 0020 / 00E0 | Sensor collection，00E0 |
| 0020 / 0042 | Sensor collection，0042 |

现场读取的 Registry IDs 保存在 [设备快照](SecondGenerationMicEvidence/device-observation.json)，
仅供审计，**今后必须重新枚举**。蓝牙地址和不相关设备已从入库证据中去除。

## 匹配固件来源（静态证据）

由版本索引定位到 Apple 官方 OTA 9M6336，实际匹配依据是归档中的
Info.plist `FirmwareVersions[33][1] = 96`、AFU 文件名及头部 PID/hardware/version，
不是网页标题。完整来源、元数据、大小与 SHA-256 见
[firmware-provenance.json](SecondGenerationMicEvidence/firmware-provenance.json)。

主映像 `p0x314-remote-v00060-hw0033-prod-signed.afu` SHA-256：
`66e98f7616856c4d76aafc547155f849c0c0812ec4e42ea6c2103f2c35e4a659`。
这证明官方包与设备公开版本属性相匹配，**未读出设备安装映像逐字节比对**。
完整 Apple 固件只保存在本地分析目录，不加入 Git。

[inspect_0314_v0060_firmware.py](inspect_0314_v0060_firmware.py) 是独立的
hash-pinned 离线工具，没有设备 API、没有放宽旧脚本身份校验。
本映像地址换算为 `AFU offset = address + 0x80`，与 B439 完全不同。
向量表、字符串指针、分支目标交叉支持此映射。可生成仅供反汇编的 ELF：

```sh
python3 Design/Research/inspect_0314_v0060_firmware.py /path/to/p0x314-remote-v00060-hw0033-prod-signed.afu --elf /path/to/new-analysis.elf
xcrun llvm-objdump -D --triple=thumbv7em-none-eabi --start-address=0x563fc --stop-address=0x568d0 /path/to/new-analysis.elf
```

## LOCK 候选读取路径（静态证据，不能直接作为探测指令）

1. `0x952A8` 的 16 字节 descriptor：entry ID 0、长度 1、名称指针
   `0x9FC07` → `LOCK`；类型字段在 +0xC。原始字节见
   [static-lock-candidate.json](SecondGenerationMicEvidence/static-lock-candidate.json)。
2. GET handler `0x563FC` 读取请求对象 `+3` 内部编号。
   `0x56442` 减 `0x3A`，范围检查后进入 `0x5651C` 的 TBH。
   表 `0x56520` 第三项为 5：内部编号 `0x3C` → `0x5652A`。
3. 该分支从对象 `+0x144` 取 DSM，entry ID 设 0，使用请求的缓冲区/长度，
   调用 `0x64252`。DSM 按 descriptor 分类选择 store，再调用 `0x6A6A2`。
4. `0x6A6A2..0x6A71C` 查找 entry，限长，从内存 store 复制到输出缓冲区并
   设置输出长度；所见路径没有 commit/持久写调用。其互斥锁的 lock/unlock
   是并发同步，不能与设备的持久 LOCK 混淆。
5. 同一 GET handler 中内部编号 `0xE1` 进入 `0x56886`，从另一对象 `+0x180`
   复制 32 字节。这不是上述 DSM entry 0 的单字节读取。

[关键反汇编](SecondGenerationMicEvidence/disassembly/lock-get-candidate.txt)
与其校验文件随仓库保存。literal pool 与 TBH 表可能被工具显示为指令，必须按
明确的代码边界和原始数据读取。这些是 LLVM 静态摘录，不是设备执行跟踪。

**缺口**：还需把这组虚函数/请求对象连接到已注册的 BLE HID Feature 表，确认
线上 report ID、方向、请求长度、keyhole/编号转换与完成应答。现有材料证明了
内部读取分支，尚不能宣称 `IOHIDDeviceGetReport(0x3C)` 就会走这条分支。
不能因同名函数或类似结构沿用 B439 的协议。原 E1 脚本不适用，本轮不新增
可执行的第二代设备探测脚本，防止静态候选被误当成验证过的读指令。

## 第一代遗留问题的本轮进展（仅限 B439 v0118）

- [CLI 传输](FirstGenerationMicEvidence/cli-transport-followup.md)：启动复制表、
  RAM 对象 `20000898`、固定 vtable 与收发函数闭环到 **UART port selector 1，
  初始化 115200**。尚无 Mac/BLE/Lightning 桥接证据，固件 GPIO 参数不是板级接线图。
- [BIR 来源](FirstGenerationMicEvidence/bir-trigger-followup.md)：完整四项已识别
  长按分支产生 BIR 0/3 或另一内部入口，未找到 event 1 生产者。全映像直接调用
  交叉检查同样没有补上来源；这是有界排查，不是“不存在”的证明。
- 原解锁前置条件与 [存储风险](FirstGenerationMicEvidence/unlock-storage-risk.md)
  仍成立：内部函数提交 factory store entry 0，运行时 LOCK 不立即刷新；
  `ds set` factory 写入要求运行时已解锁。重锁仍需可达的 CLI、实际写入结果、
  重启和回读；普通重启与已识别 user-store FactoryReset 不会自动写回 LOCK=1。
- factory bank 同含身份和校准数据。双 bank/checksum 不能替代完整导出、
  可验证回写及损坏后仍可访问的恢复入口。

以上地址和恢复语义均不能直接外推当前第二代设备。当前固件的解锁门禁、
CLI、存储提交范围与失败恢复尚需独立逐项追踪。

## 距离可靠流程仍缺什么

1. 当前 0314 固件的只读 host 请求链闭环，之后才可在超时/finally 恢复应用的
   保护下测量 LOCK。必须分别记录 API 状态、返回长度/字节及固件语义。
2. 真实、可达的解锁触发源和明确前置条件；内部事件消费者不能当主机入口。
3. 在适用的 LOCK/启动状态下仍可访问的重锁通路，写入完成、重启、回读证据。
4. 包含全部身份/校准数据的可验证备份，以及写入中断/两 bank 无效后的独立恢复。
5. 即使上述都具备，仍需另行验证免按的新音频、可靠停止与两代映射隔离。

本轮没有物理录音测试，进程在运行不等于音频已渲染或桥接经过实测验收。
