# UU 修补工具：Windows ↔ Mac 局域网辅助

Mac 版本 `2026-10-01.8`。Windows 用 UU 远程操作 Mac 时，辅助修正 UU 事件中的 Command、Option、Control 标记。Mac 保留原有离线鼠标残留标记修补和自动保持微信输入法功能。本项目采用 [MIT 许可证](LICENSE)，与 UU 官方无关联。

程序只改变已存在事件的修饰标记，不改变键码、文字、事件类型或时间戳，不补发或重放输入。`flagsChanged` 只观察。首次学习、证据迟到、配对不明确、映射未经验证时会跳过；修正计数不能代表应用操作成功。

## 安装与配置

1. 先按“源码与构建”章节构建所需程序。Mac 把生成的 `dist/UU 修补工具.app` 放入“应用程序”。先退出旧版本，再双击新应用。菜单栏出现 `UU` 或 `UU!`，不打开终端、不占 Dock。仓库不提交本地二进制和诊断文件。
2. 在 Mac 菜单选择“打开辅助功能设置”，加入并授权此应用，然后点“重试启动监听”。更新本地签名后可能需要移除旧授权条目，再重新添加。监听初始化时先松开修饰键并停住鼠标，等待同步完成。
3. Windows 双击 `dist/UUCommandBridge.exe`，会打开 Mac IPv4 设置窗口；保存或关闭窗口后继续在系统托盘运行，再次双击可重新打开设置。图标可能位于右下角的隐藏图标区域，悬停提示为“UU 局域网辅助”。这是单文件 x64 程序，不依赖 PowerShell、.NET、Go 运行时或终端窗口。托盘菜单可设置 Mac IP、暂停/恢复、导出诊断和退出；若首次添加托盘失败，会提示错误并退出。Windows 任务栏重建后会尝试恢复图标。
4. 两端填写**对方在局域网中的实际 IPv4 地址**：Windows 填 Mac 地址，Mac 填 Windows 地址。程序不会自动采用示例地址。UDP 端口固定 `47731`；不需要密钥。只接收配置 IP 和端口的报文。
5. 打开 UU 的远程画面，正常输入或点击。至少三个唯一非移动事件配对，且包含普通键或鼠标按钮事件后，自动学习当前远程窗口。在此之前不启用网络修正。
6. 在远程画面中分别按下并松开**左 Ctrl、左 Win、左 Alt**，让程序核对 UU 的 Ctrl→Command、Win→Control、Alt→Option 映射。菜单显示左侧验证进度 **3/3** 及尚未验证的左侧键名称，无需学习右侧。每一类完成左侧验证就可参与修正；若实际按住尚未验证的同类右侧键，保留该类原标记。右侧仍可自行完成验证后使用。导出诊断的 `remote.modifier_mapping_details` 保留六侧配对状态，`required` 表示是否必需；`verified_required_modifier_sides` 表示三项必需验证的进度。

Windows 使用 Public 网络配置时需核对对应防火墙规则，Ping 成功不能证明 UDP 已放行。连接不上时，请确认两端 IP、工具是否暂停、UDP 47731 是否被占用，以及 Windows 防火墙是否允许此程序与 Mac 通信；程序不会自动更改网络配置或防火墙。无需安装完整 Xcode；Mac 编译才需要 Command Line Tools，运行应用不需要开发工具。

没有自动安装服务或登录启动。两端各有单实例保护；退出菜单即可关闭。未配置 IP、网络不可用或辅助同步暂停时，Mac 仍提供离线能力。Mac 菜单的总修正计数包含离线修补，远端修正/跳过计数单独显示。

## 同步范围与状态

Windows 从卸载注册表发现 UU 安装根，核实完整进程路径、产品信息和进程启动身份。主界面和远程画面可能同属一个进程，因此通过实际输入配对学习窗口，不以进程名、Qt 类名、固定 PID 或 HWND 判断远程窗口。窗口销毁、句柄复用、进程重启后重新学习。

本地持续观察左右修饰键；只有已核实 UU 候选前台范围内的普通键标识才短暂进入有界匹配缓存。Mac 发现真实 UU 输入后请求开始发送，Windows 送最近一秒的候选事件，然后发送活跃事件和每 100 毫秒的完整状态。Windows 离开绑定窗口时停止；Mac 两秒无 UU 输入时停止详细同步。空闲只保留每秒一次、不含按键信息的连接报文，停止同步不表示所有键已松开。

时钟用单调时间和往返探测校准。最小 RTT 超过 40 毫秒、校准超过十秒、证据超过 500 毫秒、序号缺口、缓存溢出、未知键、多个匹配候选时跳过。已经放行的事件只用于后续校准，不事后修正。普通键仅支持已核实的物理键位表；特殊键和无法确定的布局原样通过。协议及字段见 [protocol/PROTOCOL.md](protocol/PROTOCOL.md)。

Mac 在 UDP 可读时接收，并在输入决策前非阻塞地消费已解码的少量内存证据；积压超过回调预算时原样放行，留给主循环处理。远端时间换算只允许半个最小 RTT 内的超前误差，源事件本身不得晚于报文发送时间；Mac 自身事件的未来时间仍严格拒绝。

配对明确的普通键、鼠标按钮、单轴滚轮使用事件发生时的修饰快照。移动和拖动需整个时间误差区间有连续、稳定证据，快照不能补证丢失的历史。其他 Mac 来源按住或尚未同步的修饰键受到保护。可靠远端证据优先于旧鼠标清理规则；不足时键盘原样通过，鼠标使用原有保守修补。

首次学习需要实际操作；尚未验证必需的左侧键、网络证据迟到和保守跳过都是可见状态。左侧3/3仅表示映射验证完成，不保证每个事件都能取得唯一、及时的证据；源事件中断后的窗口重新学习会单独显示。此版不承诺恢复所有应用因额外释放事件而改变的长按交互状态。

## 离线修补与微信输入法

Mac 离线模式只修改通过完整路径和进程启动身份核实的 UU 鼠标事件。分别跟踪 Command、Option、Control 和其他来源按住状态；启动、重连、监听中断或唤醒后等待系统同步，不以超时猜测松开。若持续显示 `resync_required` 或 `foreign_held`，停住鼠标，再按下并松开对应修饰键，稍等同步。过滤事件不等于重置系统全部键盘状态。

“保持微信输入法”默认开启，作用于当前用户会话，包括本地输入与应用切换；开关保存到用户偏好。依据 bundle ID `com.tencent.inputmethod.wetype` 识别，只选择已启用、可选择的 `com.tencent.inputmethod.wetype.pinyin` 模式。通过 Carbon TIS 接口及输入源变化通知恢复，每两秒补查，不模拟按键，不改变微信内部中英文模式。不自动安装或启用输入法。关闭或退出后允许自由切换。

## 诊断与文件写入

默认没有磁盘日志、轮转或定时清理。内存诊断最多保留两分钟、512 条、1 MiB，日常输入主要更新计数，只记录状态变化、异常和修正原因。匹配缓存与诊断分开，最多一秒、512 个事件。退出会丢弃内存内容。

两端从菜单主动导出时才写 JSON；导出不含普通键标识、文字、坐标、剪贴板、窗口标题或完整网络输入报文。设置仅在修改时保存：Mac 使用 `local.uu-command-guard` 用户偏好域，Windows 使用 `%LOCALAPPDATA%\UUCommandBridge\config.json`。启动时不会扫描或改写旧日志。

Windows “导出诊断…”打开原生保存对话框，可选择目录和文件名；取消不写文件，也不回退到临时目录。快照在网络线程生成，写盘在独立任务执行，保存及结果对话框在 UI 线程处理，不等待网络线程确认对话框。

Mac 的 `remote.keyboard_decisions` 区分成功修正、原样匹配、无候选、重复候选、时钟无效、序号缺口、学习未完成、过期源事件和本地修饰键保护；`late_keyboard_calibrations` 只统计已放行后完成配对的键盘观察，不能代表成功修正。`last_keyboard_decision` 只含动作、时间、修饰标记及决策原因。Windows 保留 `source_continuity_gap` 汇总，同时按固定原因分类，例如 `modifier_state_mismatch` 和 `input_queue_overflow`；相邻原因可能合并，不能作为精确丢包次数。

Mac 另记录 `callback_publications`（决策前消费的内存发布数）、`max_publication_wait_us`（本次运行最长发布排队时间）、`future_tolerance_accepts`（远端时钟容差命中数）和 `clock_future_tolerance_us`。最近一次有匹配的键盘决策附 `source_future_ahead_us`；`publication_busy`、`publication_backlog` 和 `publication_overflow` 表示为避免输入回调等待或超量工作而跳过。容差命中不等于快捷键成功。

仍可停止工具后显式清理旧日志，不创建监听：

```sh
"/Applications/UU 修补工具.app/Contents/MacOS/UUCommandGuard" --clean-logs
./dist/command-guard --clean-logs
```

应用清理 `~/Library/Application Support/UUCommandGuard/logs/`，命令行清理可执行文件旁的 `logs/`，保留原有容量和一小时清理规则。清理和运行实例共用运行锁。Mac 新版命令行工具与应用也共用单实例锁。

## 源码与构建

Mac 需要系统 Swift 工具链，部署目标 macOS 13 以上；应用针对当前构建机器的架构生成。Windows 源码需要 Go 1.26 或以上，无第三方依赖。

```sh
mkdir -p dist
./build-app.command "$PWD/dist/UU 修补工具.app"
./build-cli.command "$PWD/dist/command-guard"
./build-windows.command
```

Mac 脚本编译三个 Swift 文件，运行自测并进行 ad-hoc 签名；不是开发者证书签名或公证。指定路径不能是 Finder 替身，运行中的目标不可覆盖。停止应用后可指定 `/Applications/UU 修补工具.app` 构建更新。

Windows 本机 PowerShell 构建：

```powershell
Set-Location windows
New-Item -ItemType Directory -Force ..\dist | Out-Null
go test -race ./...
$env:CGO_ENABLED='0'
go build -trimpath -ldflags='-H=windowsgui -s -w' -o ..\dist\UUCommandBridge.exe .
```

若没有用于 `-race` 的 C 编译器，可执行 `go test ./...` 并记录 race 检查缺口；程序构建本身不需要 C 编译器。不要安装全局依赖来绕过检查。

离线与跨语言验证：

```sh
./dist/command-guard --self-test
xcrun swiftc -warnings-as-errors remote-peer.swift tests/remote-peer-tests.swift -o /tmp/uu-peer-tests
/tmp/uu-peer-tests
(cd windows && go test -race ./...)
python3 tests/udp-interop.py
```

`--self-test` 不创建输入监听、不切换真实输入源、不发送按键。UDP 联调使用不同的回环端口和测试文件中的内存事件，不接管真实键鼠。`--menu-bar-preview` 只展示菜单，不创建监听或保持输入法；`--version` 显示版本。`start.command` 运行项目原 `command-guard`，构建不会自动覆盖它；使用新版请替换已停止的旧二进制，或直接运行 `dist/command-guard`。

## 双机验收

已完成的自动验证及限制见 [VALIDATION.md](VALIDATION.md)。请在 Windows Codex 使用 [WINDOWS-CODEX-VALIDATION.md](WINDOWS-CODEX-VALIDATION.md) 获得本机运行证据。

以下需要用户真实操作，不由工具自动发送测试键鼠、重启 UU、唤醒 Mac 或更改权限：

- 双向 UDP 握手、实际局域网 RTT、Windows 托盘与输入钩子正常运行。
- 必需的左 Ctrl/Win/Alt 按下与松开映射，右侧按需验证；Ctrl+A/V、合法长按点击、松开后的普通点击，不能只看修正计数。
- 切回 Windows 本地应用立即停发，Mac 两秒空闲停发，菜单持续展开时同步继续。
- 本地 Mac 键盘同时按住受保护；快速重复输入、UU 重启、窗口重建、Mac 休眠唤醒后重新学习。
- 两端暂停/恢复、修改 IP、诊断脱敏、退出和再次启动；设置只在修改时写入。

如合法组合键受影响，先暂停辅助同步或退出工具，停住鼠标后再按松对应键恢复，并尽快导出最近两分钟诊断。
