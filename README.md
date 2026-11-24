# UUHarmony

**在鸿蒙手机、平板和电脑上使用远程桌面与文件传输。** UUHarmony 是独立维护的开源 HarmonyOS 适配项目，使用网易 UU 远程服务管理设备和建立连接。

[下载最新版](https://github.com/real-LEONEAST/UUHarmony/releases/latest) · [构建与发行](docs/BUILD-RELEASE.md) · [问题反馈](https://github.com/real-LEONEAST/UUHarmony/issues)

## 下载与安装

1. 在 [GitHub Releases](https://github.com/real-LEONEAST/UUHarmony/releases) 选择版本，从附件下载 ARM64 HAP。手机、平板与鸿蒙电脑使用同一个包，系统需支持 **HarmonyOS API 26 或更新版本**。
2. [v1.1.0](https://github.com/real-LEONEAST/UUHarmony/releases/tag/v1.1.0) 提供未签名的 Release HAP，发行页列有 SHA-256。真机安装需要系统认可的签名和安装方式。覆盖安装时，应用标识与签名身份需一致。 [安装和分发说明](docs/BUILD-RELEASE.md#安装和分发)
3. 打开 UUHarmony 并扫码登录 UU 账号。在「我的设备」中选择已启用 UU 远程的 Windows 电脑，或已在 UUHarmony 中开启共享的鸿蒙电脑。

## 支持的设备

| 设备 | 作为 UUHarmony 控制端 | 可被 UUHarmony 连接 |
| --- | --- | --- |
| 鸿蒙手机、平板 | 通过触控、电脑键盘和快捷键操作远端电脑，支持文件传输 | — |
| 鸿蒙电脑（PC/2in1） | 使用鼠标和键盘操作远端电脑，在同一窗口管理本机和远端文件 | 在「共享此电脑」选择屏幕和画质，按需开启键鼠控制 |
| Windows 电脑 | — | 使用已启用 UU 远程的 Windows 客户端接收连接 |

桌面共享、输入权限和显示选项取决于系统授权及连接两端的支持情况。

## 主要功能

- **远程桌面与显示器切换**。手机端从远控工具栏的「显示器」直接选择物理屏或虚拟屏，也可以查看实际连接状态。
- **手机键盘输入**。支持实时输入和整段发送，系统输入法弹出时按比例缩放远控画面，电脑键盘和快捷键可从键盘面板打开。
- **双向文件传输**。鸿蒙电脑可并排查看本机与远端目录，支持按路径查找和查看传输历史。
- **共享鸿蒙电脑**。按需开启键鼠控制，通过「停止共享」结束这次远程访问。

![UUHarmony 功能海报，展示远程控制、文件传输与屏幕共享](docs/media/uuharmony-hero.jpg)

## 从源码构建

在 Windows 上准备 DevEco Studio 26.0.0 Release（含 ArkTS SDK、Native SDK 和 OHPM）、Node.js 及 Rust 工具链。

```powershell
rustup target add aarch64-unknown-linux-ohos
$env:DEVECO_HOME = 'C:/DevEco Studio'
node scripts/build.cjs release
```

将 `DEVECO_HOME` 改为本机的 DevEco Studio 安装目录。未签名的 HAP 和 APP 会输出到 `.build/release/`。复现某个发行包时，请使用对应的版本标签。 [完整构建指南](docs/BUILD-RELEASE.md)

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `AppScope/`、`entry/` | 应用配置、ArkUI 界面、资源和 C/C++ 绑定 |
| `rust/` | 控制端核心与 WebRTC 适配 |
| `host-rust/` | 鸿蒙电脑被控端核心及其上游代码 |
| `scripts/build.cjs`、`hvigor/` | ARM64 构建入口与 DevEco 构建配置 |

## 反馈与贡献

在 [Issues](https://github.com/real-LEONEAST/UUHarmony/issues) 反馈问题时，请附上 UUHarmony 版本、控制端和被控端的机型与系统版本、网络环境、复现步骤以及界面提示。截图或日志中的账号、二维码和设备标识请先脱敏。欢迎通过 Pull Request 提交文档修正或代码改进。

## 许可证

项目附有 GNU GPL 第 3 版许可文本。各上游组件的源码来源、修改与许可条款见第三方声明。 [许可证](LICENSE) · [第三方声明](THIRD_PARTY_NOTICES.md)
