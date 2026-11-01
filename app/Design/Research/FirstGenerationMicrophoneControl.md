# 第一代 Siri Remote：电脑控制麦克风的可行性调查

日期：2026-10-12～13。基于 VibeRemote `17664de`。未修改运行时代码、按钮映射或安装版本。第三阶段读取了实机 LOCK，并仅发送一次固定的零时长 `31` 诊断请求；没有执行解锁、持久化写入或实际麦克风启动。

## 结论

**已找到软件控制候选路径，并读到当前遥控器的 LOCK 为 `1`。受锁限制的 `31` 路径暂不能用于免按录音；尚未验证其他可用的软件启停入口。**

第二阶段已完成本机 AppleBluetoothRemote 驱动提取、匹配的 Apple 官方固件获取及重点函数反汇编。固件包含 `0x98` 音频流启停和 `0x31` 按键模拟两个入口。`0x98` 单独不能从普通连接状态启动麦克风，也不能解除松手定时关闭；`0x31` 可进入 Siri 的同一内部通知路径，但受持久化 `LOCK` 配置约束，第三阶段已通过 IOHID Feature GET `E1` 读到 `01`，零时长 `31` 请求返回通用错误。该错误符合 LOCK 拦截，但没有独立空口记录证明它经过哪一层；不能等同于完整的软件录音验证。

已知工作链路是：物理 Siri 键触发遥控器发送 Opus → PacketLogger 捕获 → VibeRemote 解码 → 虚拟声卡 → 输入法。电脑上保持快捷键按下、忽略 release、保持播放器运行，只影响后半段，不能凭空获得遥控器没有发送的声音。释放后的尾包也不能视为持续采集。

“输入法按一下开始、再按一下结束”可以在电脑端适配；这不等于解决遥控器必须按住的限制。若实现，应把远端采集状态、映射按键状态、输入法录音状态分开，同时保留现有两代映射和尾音排空机制。

## 调查方式与边界

使用用户指定的 REA skill。旧路径 `skill-src/reverse-engineer-anything/SKILL.md` 已返回 404，实际读取仓库现行 [SKILL.md](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md)（元数据版本 39），及 connection-and-recovery / native-and-artifacts 指南。

第一阶段执行源码调查、系统属性读取、已存在抓包的被动分析。第二阶段使用 Python、macOS libcompression 和 Xcode 的 llvm-objdump 分析驱动与固件。没有连接的 REA MCP；此前独立 CLI 获取/诊断未完成，已结束本轮启动的 npm 进程。未注册 MCP、未安装第三方反编译引擎。以下 E 编号是本报告的本地证据索引，**不是 REA 引擎返回的 Evidence ID**。静态调用路径不等于实际执行成功。

## 证据索引

### E1：本机身份（只读、实测）

`ioreg` 当前遥控器：VendorID 76，ProductID 621 / `0x026D`，hardware revision `0A00`；固件原始属性 `B000750001001801300033022000040431001800C1000100`。第二阶段通过 OTA 元数据对照其主程序/触控/蓝牙组件版本 `0118/0404/0233`，不是凭字符串外观猜测。

AppleBluetoothRemote 的 plist 包含产品 614、621、788、789；这仅证明驱动匹配范围，不证明每个产品都支持相同命令。其内核实现不作为独立可直接读取的 Mach-O 放在 kext 目录；第二阶段已从 kernelcache 提取并反汇编，见 E6。

### E2：本机现有抓包（只读、有限覆盖）

观察文件：`~/Library/Application Support/VibeRemote/MicrophoneBridge/packets.log`。读取快照 1,067,755 字节、5,171 行，SHA-256 `44f83d02f5fd4b7b3b11830be897203a1d8d41a633a38c5048b6e94190549445`。

- HCI `004D` 的 ATT `0023` 通知在 21:15:21.078 出现 `1B 23 00 00 10`，在 21:15:27.424 出现 `1B 23 00 10 00`，符合现有旧款解析器的开始/结束标记。
- 快照内未见这两个标记之间对应的 host→remote ATT 写入。之后 21:15:30、21:16:15、21:17:00、21:17:45 可见保活写入。
- 这 32 次写入的实际空口值是 **`FF AF`**，目标 ATT `001D` 或 `0020`；有 32 个 `13` Write Response。与源码中“空口应只有 AF”的注释存在差别。写入得到响应不证明它是麦克风命令，也不证明每个接口的报告映射正确。
- 这些保活写入后，快照未出现新的已识别语音开始标记；不能把 `AF` / `FF AF` 当成已证实的免按录音开关。

捕获包含旧记录回放、此前会话残片及期间 bridge 重启，不能据此测量准确的物理按键到音频延迟，也不能宣称完整覆盖所有通信。当前 HCI handle 不能硬编码为设备身份。只分析控制字节/形状，没有解码或保存语音内容；原始捕获会轮转，未加入仓库。

### E3：本项目源码（静态）

- `RemoteInputHandler.enableRemoteInputStreaming` 与保活路径写输入使能报告。
- `RemoteHIDChannel.writeInputEnable` 写 `AF` 并订阅输入报告。
- `SiriRemotePacketParser.oldProtocolEvents` 被动解析 ATT `0023` 的开始、数据、结束。
- `VirtualAudioOutput` 保持播放器运行以减少起音延迟；不是发送到遥控器的录音命令。

这些代码没有实现已验证的远端麦克风 toggle。其注释里的固件结论不能替代固件分析。

### E4：第一代公开实现（原作者源码）

- [Yanndroid/SiriRemote-Linux 初始化](https://github.com/Yanndroid/SiriRemote-Linux/blob/b3840c4df943f9f6f7c33a236bc8986c3c13dd06/remote/remote.py#L47-L56)：`001D ← AF`，`0024 ← 01 00`。作者 README 没有确证音频测试，因此只能证明初始化写法。
- [Jack-R1/SiriRemoteVoiceControl 操作说明](https://github.com/Jack-R1/SiriRemoteVoiceControl/blob/973f006de7b7d380c2472eb35424214837cd1aad/README.md#L108-L112)要求按住麦克风键；[解析器](https://github.com/Jack-R1/SiriRemoteVoiceControl/blob/973f006de7b7d380c2472eb35424214837cd1aad/SiriRemoteVoiceControl/main.m#L290-L310)与本机两个标记一致。该路径是被动接收，没有找到发往遥控器的免按录音命令。

限定：只覆盖这些公开工作实现；没有发现实现不等于固件不存在实现空间。

### E5：其他代际与 PushToTalk（第一阶段公开线索）

- [azais-corentin/siri-remote](https://github.com/azais-corentin/siri-remote/blob/3b1d4e0a0fe0317f77368dee9f811e656fe9cb95/README.md#L84-L89)明确面向第三代，按住 Siri 收音。不能将其限制直接外推第一代。
- [SiriRemoteForge 作者实验记录](https://github.com/HOLODATA-COM/SiriRemoteForge/blob/4c65969c71c5f3c81cfa55b5ec3b9efb5658be32/docs/mic-reverse-engineering.md#L214-L281)称 Apple 驱动 PushToTalk 路径对 PID 788/789（`0314/0315`）发 Feature `99`。这不是当前 `026D`。其新款负测试既不能证明第一代失败，也不能证明该名字意味着无按键录音。

该 living document 保留多次已撤回的早期结论。IOHID 收不到回调不等于空口没有音频；本项目的 PacketLogger 成功路径正好说明需要区分这两层。

### E6：本机 Apple 驱动（第二阶段，独立静态验证）

从本机 Preboot 的 IMG4 kernelcache 解出 LZFSE Mach-O fileset，定位 `com.apple.driver.AppleBluetoothRemote`（版本 1000.6、arm64e、699 个符号）。来源哈希与提取方式见 [driver-provenance.json](FirstGenerationMicEvidence/driver-provenance.json)。为 llvm-objdump 制作的 analysis-view 只替换顶层 Mach-O header/load commands，保留全局偏移和虚拟地址；它是转换后的分析视图，不是独立可加载 kext。

`AppleEmbeddedBluetoothDeviceManagement::setPushToTalkPropertyWL`，本机地址 `0xfffffe00091ef5a0`：

- `0xfffffe00091ef6a4..6ac` 判断 `(ProductID & ~1) == 0x0314`。
- 允许的 `0314/0315` 在 `0xfffffe00091ef6ec` 调用 `setFeatureReportWL(0x99, &value, 1)`。
- 其他 PID 进入 `unsupported for PID` 分支，返回 `0xe00002c7`。当前 `026D` 不符合条件。
- `setFeatureReportWL @ 0xfffffe00091f5538` 构造 `[reportID, payload...]`，报告长度加 1，再调用 Feature SetReport。

**结论范围：这个系统属性不能直接替第一代开启麦克风。不是固件不存在其他接口的证明。**

### E7：与实机匹配的量产固件（第二阶段，实际文件）

Apple 官方 [WirelessRemoteFirmware.2 OTA 118](https://updates.cdn-apple.com/2019/ios/041-04421-201908730-71130D70-AFC7-11E9-83A5-4F41F70D717D/com_apple_MobileAsset_MobileAccessoryUpdate_WirelessRemoteFirmware_2/afb28cfdde5770cc4807bc0ccc52e47a457961ed.zip)，下载包 720,908 字节。分析对象是 `B439-remote-v0118-hw000A-prod-signed.afu`，446,984 字节，SHA-256：

`9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc`

AFU 头明确包含 PID `026D`、硬件 `000A`；Info.plist 的硬件 10 配置和组件版本与 E1 一致。它是第一代 Rev A/B439，不能把更早 `0266` 的芯片和指令集结论直接套用。文件含未加密 Thumb-2 代码与浮点指令，确切 MCU 型号尚未确定。

整个 AFU 的文件偏移 0 对应 `0x08008000`，不是去掉文件头后从该地址开始。复位向量 `0x0800fcf1` 对应文件 `0x7cf0` 的启动指令；默认向量 `0x0800fd29` 对应自循环。字符串指针也交叉支持该映射。

源码、哈希和地址模型见 [firmware-provenance.json](FirstGenerationMicEvidence/firmware-provenance.json)。仓库不包含 Apple 完整固件或内核镜像。

### E8：Feature `0x98` 是音频流控制，但有状态前提

`CmdProcessorReportSet @ 0x08021470` 通过 report ID 分发。注册表 `0x08064540` 声明 report type 3、ID `98`、可读写、参数长度 1。通用验证函数 `0x0805d204` 检查类型、ID、读写方向和参数长度；不是仅仅看到名字相似的字符串。

`0x08021696..6a6` 读取参数：非零向主状态机发送 `0x0F = EVT_ENABLE_AUDIO_STREAMING`，零发送 `0x11 = EVT_DISABLE_AUDIO_STREAMING`。**这些是固件端报告参数；当前 macOS IOHID / ATT 的封装还未证明，不能当成可直接复制的发送指令。**

完整状态表解码后，与音频相关的行为如下：

| 当前状态 | 事件 | 下一状态 / 动作 |
|---|---|---|
| 5 CONNECTED | `0x0E`，Siri down | 6，AudioEnable |
| 5 CONNECTED | `0x0F`，`98` 非零 | 本状态无对应转换 |
| 6 CONNECTED_WITH_AUDIO | `0x0F` | 7，AudioEnableStreaming |
| 7 STREAMING | `0x12`，Siri up | 8，AudioButtonUp，安排关闭计时 |
| 7 STREAMING | `0x0F` | 留在 7，无动作 |
| 8 STREAMING_TIMEOUT | `0x0F` | 回到 7，无动作，不取消关闭计时 |
| 8 STREAMING_TIMEOUT | `0x0E` | 回到 7，AudioDisableAnEnableAgain，取消旧计时 |
| 6 | `0x11`，`98` 零 | 5，AudioDisableAndFlush |
| 7、8 | `0x11`，`98` 零 | 5，AudioDisable |

关闭回调 `0x08021ef0` 只投递 signal；消息处理 `0x0801ca5e` 无条件提交 `0x11`。所以在松手后重复发送 `98` 非零，不能仅凭状态回到 7 就断言保住录音。真正清除计时和 signal 的代码位于 `AudioDisableAnEnableAgain @ 0x08020c04`。

`Audio Fast switch` CLI 只调整对象字节 `+0x107`，使 AudioEnable 后自动投递流启动事件；这不是另一个已证实的远程上电开关。报告 `0x96` 则追到 `EnableInputInternal` 的 input 4 位掩码，不应凭邻近的 report ID 称它为麦克风开关。

### E9：Feature `0x31` 可以进入 Siri 按键模拟路径，但受 LOCK 限制

`CmdProcessorReportSet` 的 `0x31` 分支在 `0x08021556` 检查全局字节 `0x200027f0`。非零直接拒绝；零且参数恰好 5 字节才调用 `0x0803105c`。这与固件 CLI 的 `Button press simulation` 使用同一入口。

参数布局是 button mask（1 字节）、延迟毫秒数（16 位大端）、持续毫秒数（16 位大端）。Siri mask 为 `0x10`。计时代码把值乘 1000 传给调度器，单次持续时间上限为 65.535 秒。`mask=0` 返回错误，`duration=0` 被丢弃，二者都不能当成 release。到期会清除模拟状态；重发续期与立即取消的可靠性未得到实测。`98` 零可以投递音频停止事件，但不等于取消仍在运行的模拟按键计时。

静态调用链：

```
Report 31 → 0803105C → ButtonProcessor event 0D / 08030752
  → 模拟状态 +2E4 / +2E8 → GPIO 状态合成 08030310
  → 0802FA10 检查 Siri bit 10 → 0802FB8C 发 BIR notification 4
  → 主通知处理 0802228C（source C80F），event 4 → 08022678
  → 08022962 / 08022972 → 音频事件 0E / 12
```

主通知处理的 BIR 分发表 `0x08022460` 中 event 4 指向 `0x08022678`。这条链路说明候选会影响真正的音频状态机，而不只是给电脑伪造一个键盘按键。它也可能产生正常 Siri HID 边沿，影响现有 Siri mapping；未来实验应独立隔离，不能直接塞入现有按钮处理。

LOCK 不是本轮已证实的硬件熔丝。初始化 `0x080502f4..5030c` 从 DSM 持久化 entry 0 读取它，entry 表 `0x0806927c` 中名称为 `LOCK`、长度 1。读取失败路径设为 1；缺失 entry 的初始化路径写 0，因此不能仅凭量产固件文件名断言设备一定锁定。第二阶段定位到了内部解锁函数，但当时将其标成 CLI handler 的说法不准确；具体入口见第四阶段。第三阶段已读取当前 LOCK=1；第四阶段定位了 CLI 的重新上锁路径，但蓝牙可达性和实机恢复仍未验证。未执行解锁、持久化写入或遥控器重启。第二阶段检查的普通 Main GetReport 没有读取 LOCK 的入口；后续在 PMM 找到 E1，见 E12。

**目前最有价值的候选是 `0x31` 软件模拟 Siri，而不是单独 `0x98`。静态存在不等于量产设备当前允许。**

## 复核与下一步

只读工具 [inspect_b439_firmware.py](inspect_b439_firmware.py) 在执行前校验精确 SHA-256，解码 29 条报告注册项和 20 个状态，可选生成供 llvm-objdump 使用的 ELF 包装。它没有蓝牙、USB 或设备写入功能。关键结果保存在 [audio-tables.json](FirstGenerationMicEvidence/audio-tables.json)。整个镜像的线性反汇编会包含数据、字符串和 literal pool，必须从已核对的函数边界分析，不能把每一行都当指令。

下一轮按以下顺序推进：

1. 核对 LOCK 的可读路径及实机状态，先确认 `31` 是否可用；不要把“有 unlock 字符串”视为现成接口。
2. 核对第一代 Feature/ATT 的 report ID 与 payload 封装。E2 的 `FF AF` 差异说明只看 IOHID 返回成功不够。
3. 若路径可达，做有明确时限的独立诊断，验证无人按键时采到**新产生的声音**，随后停止命令确实停止；同时避免模拟 Siri 边沿触发日常 mapping。有限时长成功也不能证明无限时长或自动续期可靠。
4. 再考虑接入 VibeRemote 的独立采集控制状态。保留两代现有 mapping、物理 Siri 工作路径和尾音排空机制；本轮不实施该功能。

本次不刷固件、不解除配对、不随机枚举报表写入、不修改系统安全配置。

## 问题完成度

| 问题 | 状态 |
|---|---|
| 当前声音怎样到达电脑 | 已有源码与抓包交叉验证 |
| 已知 enable/保活是否就是免按录音 | 没有证据支持；当前写入未触发新会话 |
| 是否有公开、第一代可复用的软件 start/stop | 在列出的公开实现中未找到 |
| 第一代固件是否存在音频相关 host 命令 | 已静态定位 `98` 和受 LOCK 限制的 `31` 路径 |
| `98` 单独是否能解决免按录音 | 状态机与计时路径不支持这个结论 |
| 当前量产遥控器能否软件启停新声音 | 未解决；LOCK 实读为 1，零时长 31 返回错误，尚无实际启动/停止音频证据 |
| 能否适配输入法 tap-to-toggle | 软件层可设计；本轮未实施，不解除远端采集限制 |


## 第三阶段：LOCK 与 macOS 实机接口（2026-10-13）

### E12：直接读取 LOCK 的固件路径

第二阶段只查了 Main 的 GetReport，未覆盖 PMM。现在定位到 PMM 的 `CmdProcessorReportGet @0802493C`：`E1` 分支 `08024B40..08024B58` 调用 DSM read `08033482`，entry ID 为 0，正是 `LOCK`。PMM 初始化 `08022EF0` 调用共享 DSM singleton `08033538` 并存到对象 `+140`。

注册表 `08064F20` 共 12 项，其中 `08064F98` 的 `E1` 为 type 3、可读、不可写、长度上限 1。表注册 group/interface 为 0，且该注册不受前面的 CLI LOCK 条件限制。这是只读入口，不是解锁命令。

蓝牙 Main-MCU 路径使用内部 handle index→group 表 `080669C4`（`FF 00 01 FC FF FF FF`）；group 0 对应内部 index 1。该 index 不是 ATT handle，不能直接把它当作 `001D`。GET 从对象 `+246` 的 keyhole report ID 取目标；`0802A7AA` 保存该 ID。WRITE 从蓝牙消息中的首字节提取 report ID，其余作为 payload。完成路径将内部状态转为 radio read/write response，见 [lock-read-and-ack.md](FirstGenerationMicEvidence/lock-read-and-ack.md)。不能把 ATT 应答视为普通 Feature payload 中的状态字节。

### E13：在这只遥控器上的有限测试

本机 BLE `IOHIDUserDevice` 有 8 个接口，描述符均显示 Feature `FF`、最大 209 字节；但这**不代表只能通过 API 访问 FF**。在 Vendor `FF00` / Usage `000B` 接口上直接调用 Feature GET `E1` 成功了。

先确认 `026D + 0A00 + Bluetooth Low Energy`。首次非 seize 打开返回 `e00002c5`（独占访问），没有继续读写。随后短暂退出 VibeRemote，释放它原有的 HID 所有权，进行以下调用；每次都在 finally 中重新打开已安装的应用：

| 本地时间 | 调用 | 结果 |
|---|---|---|
| 08:31:35.765 | GetReport(Feature, E1) | success，长度 2，`E1 01`，87 ms |
| 08:31:35.867 | GetReport(Feature, FF)，对照 | success，长度 2，`FF AF`，42 ms |
| 08:32:37.911 | 再次 GetReport(Feature, E1) | success，`E1 01`，176 ms |
| 08:32:37.934 | SetReport(Feature, 31)，buffer=`31 10 00 00 00 00` | `e00002bc`（通用错误），23 ms |
| 紧接其后 | GetReport(Feature, E1) | success，`E1 01` |

`31` 的 5 字节 payload 为 Siri mask `10`、delay=0、duration=0。即使 LOCK 未挡住，ButtonProcessor `0803075A..08030760` 也在取消计时器、写模拟状态之前检查 duration=0 并退出。非零 mask 保证不会误走 mask=0 的另一条错误路径。这次请求用于验证接口拒绝，**不用于开始收音**。没有发送非零时长的模拟按键、`98`、unlock、重置或固件写入。

读取结果与固件 DSM 路径共同支持当前 LOCK=1；`31` 的返回错误与锁检查相符。然而退出应用也停止了其 PacketLogger supervisor，所以没有独立空口捕获本次请求。`e00002bc` 本身无法区分固件 LOCK 拒绝、外层传输拒绝或其他错误，不能声称已抓到 ATT 错误。API 调用 GetReport 可能由系统内部转换为 keyhole 选择/读取，也不能称其绝对没有空口选择写入。

原始 API 结果（不含声音与其他设备流量）保存于 [live-lock-probe.json](FirstGenerationMicEvidence/live-lock-probe.json)。可复核工具为 [probe_first_generation_lock.py](probe_first_generation_lock.py)，默认仅 GET `E1`，显式参数才允许一次固定的零时长请求；没有任意 payload 或 unlock 功能。注册 ID 会随重新枚举变化，须重新读取。

08:32:41 日志确认 Bridge 重新启动成功；本轮没有进行物理按键与音频验收。没有更改 Siri 映射、偏好设置、安装包或两代运行逻辑。

### 本阶段边界与后续

现阶段不能把候选命令接入产品作为免按录音开关。继续深入的重点是查找不依赖 LOCK 的临时音频控制路径，或静态核对 unlock 的限制和恢复方式；不能从“存在 unlock 字符串”跳到对遥控器执行持久化解锁。若以后获得可用入口，仍需验证无人按键时的新声音、明确的停止行为，以及与现有按钮映射的隔离。


## 第四阶段：能否解锁、风险与恢复（2026-10-13，仅静态）

**固件确实支持改变 LOCK，并存在写回 1 的代码路径；目前仍没有“从这台 Mac 解锁，再可靠恢复”的完整、经过验证的操作链。** 本阶段没有运行诊断脚本，没有调用设备读写 API，没有退出/重启应用或遥控器，也没有修改按钮映射。

### E14：解锁入口并非普通的 E1 写入

- `E1` 注册为只读。不能把读到的 `01` 改成 `00` 再回写来解锁。
- 内部解锁函数 `08023160` 确实向 factory store 的 entry 0 写入一个零字节并提交；它不在这里清除当前 RAM 中的 LOCK，须重启后由启动逻辑重新读取。
- 已核对的调用方包括固件更新器和内部通知分发。更新路径检查特殊镜像类型 `D0`、已完成的更新位图，以及 unlocker 与应用版本匹配；它位于含签名校验阶段的状态机中。目前手上没有可用的匹配 unlocker 镜像，也没有完整的 host 操作流程。
- 内部通知路径已追到 BIR event 1 → REMOTE event 5 → PMM event 5 → 解锁函数，但尚未找到 BIR event 1 的实际触发源，不能认定某个物理手势可解锁。CLI 的字节输入经过虚拟 I/O 对象，物理传输尚未确认；固件中的 `hid_cli.cpp` 是 HID 诊断命令线索，不能凭文件名认定 CLI 可经 HID 访问。因此不能把函数存在、某个事件编号或普通开发固件，等同于能从 macOS 发出的安全解锁命令。此前的“CLI unlock handler”标签已更正。

依据：[unlock-entry-and-fwu.md](FirstGenerationMicEvidence/unlock-entry-and-fwu.md)、[unlock-notification-entry.md](FirstGenerationMicEvidence/unlock-notification-entry.md)。

### E15：重新上锁有代码，但恢复能力尚未证明

内部 CLI 的 `ds set`（处理函数 `08024D6C`）允许按名称或 ID 指定 entry。LOCK 属于 factory 类；当运行中的 LOCK 已为零时，该分支可以调用底层 store 写入 entry 0 的一字节值 1。这是明确的重新上锁候选路径，而不是推测存储应该可写。

限制是：尚未证明当前 Mac/Bluetooth 可以访问此 CLI；只找到命令解析器和写入分支不等于拥有恢复接口。写回持久 LOCK 后仍需再次重启并读取 E1，才可检验启动门禁恢复。普通重启只重读当前值，不会自动把零变回一。

已检查的 `FactoryReset @0802341C` 操作 user store 而不是保存 LOCK 的 factory store，所以不能把“恢复出厂”当成重新上锁办法；这条流程清除未保护的用户条目；其中三个配对相关条目有保护标志，但这不能推导所有恢复出厂手势都保留完整配对。底层存储采用交替 bank、序号与校验，并在加载失败时尝试另一份；两份都无效时会建空库，而非还原原数据。尚未做断电恢复或真机失败恢复试验。

依据：[unlock-storage-risk.md](FirstGenerationMicEvidence/unlock-storage-risk.md)。

### 目前能够给出的风险判断

| 项目 | 证据与判断 |
|---|---|
| 是否临时开关 | 不是；解锁修改持久配置，重启后仍保留 |
| 是否不可逆熔丝 | 所见路径是可改写存储，不是已证实的一次性熔丝 |
| 是否只影响麦克风 | 不是；LOCK 同时限制按键模拟、工厂配置写入和部分调试命令 |
| 是否必然清配对/校准 | 解锁函数逻辑上只改 entry 0，未见主动清配对；但它提交的整个 factory bank 同时含序列号、蓝牙地址、麦克风及蓝牙校准数据，失败影响不能承诺只限于 LOCK |
| 写入失败能否识别 | 解锁函数先打印成功意图，再提交，且没有在该函数内检查返回值；不能以提示文本认定成功 |
| 能否保证恢复 | 不能；有重锁代码，但尚无验证过的 CLI 访问、回写、重启和回读全流程 |
| 解锁后一定能免按收音吗 | 不能保证；31 模拟路径和实际采音、停止、映射隔离仍需要单独验证 |

当前不具备实施解锁实验的恢复条件。下一步有价值的只读工作是确定内部通知的真实来源和 CLI 的外部传输，优先补齐重新上锁的可达性；不应先解锁再寻找恢复办法。


## 第五阶段：2026-10-13 换机器接手（只读与静态）

本报告前四阶段的“本机/实机”指历史 026D/0A00/v0118 设备。当前机器实际
连接另一只 0314/0021/0060 第二代设备；其 LOCK 未测得，不能沿用 E1 01。
身份、匹配固件、候选读取分支及尚未执行查询的原因见
[当前设备报告](SecondGenerationMicrophoneControl.md)。本轮没有发送设备命令。

B439 的两项静态调查取得进展：

- [CLI transport follow-up](FirstGenerationMicEvidence/cli-transport-followup.md)：
  `20000898` 的初始化、虚表和收发代码已闭环到 UART port 1 / 115200。
  `ds set` 重锁代码背后的传输不再完全未知，但 Mac/BLE/Lightning 的访问路径
  与失败恢复仍没有验证。不能把 UART 固件参数当成物理接线图。
- [BIR trigger follow-up](FirstGenerationMicEvidence/bir-trigger-followup.md)：
  已完整排查四项已识别长按分支，均未产生 event 1；其生产者仍未找到。
  下游解锁链存在，不证明有可用手势或可注入的主机事件。

第四阶段的存储风险和前置条件保持不变：没有可靠的完整备份/恢复与可达重锁
通路；普通重启、已识别 FactoryReset 和双 bank 都不能替代该流程。
当前第二代的解锁与恢复语义需要独立分析，不能使用 B439 地址。
