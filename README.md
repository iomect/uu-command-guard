# UU远程快捷键修复工具：Windows 控制 Mac

用于网易 **UU远程** 的 **Windows 控制 Mac（macOS）** 场景，帮助排查和修复由 Command、Option、Control 标记丢失或残留引起的**快捷键冲突、快捷键失效**，例如 Ctrl+C 无法复制、Ctrl+V 无法粘贴或只输入 v，以及 Ctrl+A、Ctrl+X 等组合键异常。

当前版本 **1.3.0**，Mac 内部版本 `2026-10-01.10`。采用 [MIT 许可证](LICENSE)，与 UU 官方无关联。

只修改已有事件的三个修饰标记，键码、文字、事件类型和时间戳保持原样，不补发或重放输入；修饰键事件本身只观察。Mac 另提供离线鼠标按钮/滚轮修补和微信输入法保持。

## 下载与安装

| 平台 | 下载 |
| --- | --- |
| Apple Silicon Mac | [Mac arm64](https://github.com/iomect/uu-command-guard/releases/download/v1.3.0/UUCommandGuard-Mac-arm64.zip) |
| Intel Mac | [Mac x86_64](https://github.com/iomect/uu-command-guard/releases/download/v1.3.0/UUCommandGuard-Mac-x86_64.zip) |
| Windows x64 | [Windows x64](https://github.com/iomect/uu-command-guard/releases/download/v1.3.0/UUCommandBridge-Windows-x64.zip) |

[发布页](https://github.com/iomect/uu-command-guard/releases) 提供 SHA256 校验文件；ZIP 包含程序、许可证及安装说明。**请同时更新两端并先退出旧版。**

1. Mac：支持 macOS 13 以上。把 `UU 修补工具.app` 放入“应用程序”，双击后从菜单打开辅助功能设置并授权，再点击“重试启动监听”。应用采用 ad-hoc 签名，未经 Apple 公证；若被阻止，请在“隐私与安全性”中允许打开。更新签名后可能需要移除旧授权，再重新添加。
2. Windows：解压并双击 `UUCommandBridge.exe`，填写 Mac IPv4。保存或关闭设置窗口后在托盘运行，再次双击可打开设置；没有运行时依赖。托盘可暂停、设置 IP、导出诊断及退出。
3. 两端填写对方实际局域网 IPv4。UDP 固定 `47731`，只接收配置 IP/端口；无认证或加密。连接异常时检查 IP、暂停状态、端口占用和 Windows 防火墙，程序不会自动修改防火墙。
4. 在 UU 远程画面中正常输入或点击，完成远程窗口学习；至少需要三个唯一配对，包含普通键或鼠标按钮。然后**单独按下并松开左 Ctrl、左 Win、左 Alt**，菜单显示左侧 **3/3** 后完成映射验证，右侧按需学习。

Mac 提示“Apple 无法验证”或“应用已损坏”时，先尝试在“隐私与安全性”中允许打开。若仍被阻止，确认应用来自本仓库发布页且已放入“应用程序”，可在终端执行：

```sh
xattr -cr "/Applications/UU 修补工具.app"
```

该命令递归清除本应用的扩展属性（包括下载隔离标记），执行后重新双击。它不修复真正损坏的文件，也不授予辅助功能权限；若仍无法打开，请重新下载并核对 SHA256。

没有自动登录启动或后台服务；两端各有单实例保护，从菜单退出即可关闭。辅助网络未配置或暂停时，Mac 离线能力仍可使用。

## 修复范围与性能

- 动态学习 UU 当前实际映射，支持三类互换及多个源键映射到同一类。更改 UU 映射后，请重新分别按松三个左侧键；工具在可靠矛盾边到达时撤销旧映射，不直接读取 UU 设置。
- 通用组合键修复需要检查键盘事件上的修饰标记，不只针对 Ctrl+A/C/V/X。临时按键标识只用于有界内存配对和两端 UDP，不读取输入文字、不写入诊断。未核实的特殊键或布局原样通过。
- **鼠标移动和拖动不参与处理**：Mac 不订阅，Windows 直接透传，不解码、不入队或转发。保留键盘、按钮和单轴滚轮的标记修复；默认关闭第二层键盘诊断监听，减少逐事件状态格式化。
- 证据迟到、配对不唯一、时钟异常或未验证的源侧按住时保守跳过。本地 Mac 键盘按住和未同步的修饰类受到保护；修正计数不代表应用操作成功。

退出远程窗口、源事件中断或对端停止后需重新验证；同窗口单纯空闲保留已确认映射。只移动鼠标不会维持详细同步。启动、重连或唤醒后先松开修饰键；持续等待时分别按松对应键。

“保持微信输入法”默认开启，可在菜单关闭并保存偏好。通过系统 TIS 接口保持已启用、可选择的 `com.tencent.inputmethod.wetype.pinyin` 模式（应用 bundle ID：`com.tencent.inputmethod.wetype`），不模拟按键、不自动安装或启用输入法，不改变微信内部中英文模式。

协议、时间门限及恢复规则见 [PROTOCOL.md](protocol/PROTOCOL.md)；自动验证与实机限制见 [VALIDATION.md](VALIDATION.md)。实际 CPU 降幅、高频快捷键及长按交互仍需双机验证，Windows 本机验收见 [WINDOWS-CODEX-VALIDATION.md](WINDOWS-CODEX-VALIDATION.md)。

## 诊断与设置

默认不写磁盘日志；诊断仅在内存保留最近两分钟，最多512条、1 MiB，退出即丢弃。两端菜单的“导出诊断”允许选择目录和文件名，取消不写文件；导出不含普通键标识、文字、鼠标坐标、剪贴板、窗口标题或完整输入报文。

设置仅在修改时保存：Mac 使用 `local.uu-command-guard` 偏好域，Windows 使用 `%LOCALAPPDATA%\UUCommandBridge\config.json`。诊断包含映射进度、实际目标类及修正/跳过原因；更多字段见源码和协议。

排障时可先退出 Mac 应用，再运行其可执行文件并附 `--diagnostic-session` 比较两层键盘标记；正常启动恢复默认。`--clean-logs` 仅显式清理旧日志，不创建监听：应用旧目录为 `~/Library/Application Support/UUCommandGuard/logs/`，命令行版为可执行文件旁的 `logs/`；正常启动不扫描或清理旧日志。

## 源码与构建

Mac 编译需要 Command Line Tools；Windows 编译需要 Go 1.26 以上及 Python 3。无第三方运行时依赖，本地构建不会自动覆盖运行中的应用。

macOS 构建：

```sh
mkdir -p dist
./build-app.command "$PWD/dist/UU 修补工具.app"
./build-cli.command "$PWD/dist/command-guard"
./build-windows.command
```

Windows PowerShell 构建：

```powershell
python tools/build-windows-resources.py
Set-Location windows
New-Item -ItemType Directory -Force ..\dist | Out-Null
go test ./...
go build -trimpath -ldflags='-H=windowsgui -s -w' -o ..\dist\UUCommandBridge.exe .
```

离线验证：

```sh
./dist/command-guard --self-test
xcrun swiftc -warnings-as-errors remote-peer.swift tests/remote-peer-tests.swift -o /tmp/uu-peer-tests
/tmp/uu-peer-tests
(cd windows && go test -race ./...)
python3 tests/udp-interop.py
```

自测和 UDP 联调不创建输入监听、不切换真实输入法、不发送系统输入。Windows 无 C 编译器时使用 `go test ./...` 并记录 race 检查缺口。图标 SVG 与平台资源在 `assets/`；Windows `--ui-preview` 只预览设置界面，不启动钩子或网络。

[GitHub Actions](https://github.com/iomect/uu-command-guard/actions/workflows/build.yml) 构建 Mac arm64、Mac x86_64、Windows x64，执行离线验证、签名及隐私检查并生成 ZIP/校验文件。推送 `v*` 标签或手动填写 `release_tag` 可发布；全部构建成功后才发布，Artifacts 保留90天。
