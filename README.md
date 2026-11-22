# UUHarmony

![UUHarmony 功能海报，展示手机、平板和电脑之间的远程控制、文件传输与屏幕共享](docs/media/uuharmony-hero.jpg)

**在鸿蒙手机、平板和电脑上访问远端桌面。** 登录 UU 账号，从「我的设备」连接已启用 UU 远程的 Windows 电脑或已开启共享的鸿蒙电脑。出门时可以回到电脑上取文件，也可以换一台设备继续操作。

UUHarmony 是独立维护的 HarmonyOS 适配项目。设备管理和远程连接使用网易 UU 远程服务。

## 能做什么

- **远程桌面**。在手机和平板上使用触控和虚拟键盘，在鸿蒙电脑上使用鼠标、键盘和快捷键。会话中可切换远端显示屏，并查看实际连接状态。
- **双向传文件**。鸿蒙电脑在同一个窗口中显示本机与远端目录，可输入路径或选择文件夹。已完成的任务可以在传输历史中查找。
- **共享鸿蒙电脑**。在「共享此电脑」选择屏幕和画质，按需开启键鼠控制。停止共享可结束此次远程访问。

## 支持的设备

手机、平板和鸿蒙电脑共用同一份 **ARM64 HAP**，需要 **HarmonyOS API 26 及以上**。桌面共享、输入权限和可用的显示选项取决于设备系统与会话两端的支持情况。

| 设备 | 用法 |
| --- | --- |
| 鸿蒙手机、平板 | 作为控制端连接在线电脑，使用触控、虚拟键盘和文件传输 |
| 鸿蒙电脑（PC/2in1） | 作为控制端操作远端桌面，也可按系统授权共享本机 |

## 从源码构建

准备 DevEco Studio 26.0.0 Release（含 ArkTS SDK、Native SDK、OHPM）、Node.js 和 Rust 工具链。在 Windows 的当前 `main` 工作副本中运行以下命令。

```powershell
rustup target add aarch64-unknown-linux-ohos
$env:DEVECO_HOME = 'C:/DevEco Studio'
node scripts/build.cjs release
```

把 `DEVECO_HOME` 改为本机的 DevEco Studio 安装目录。未签名的 HAP 和 APP 会输出到 `.build/release/`，文件名包含应用名称和版本号。真机安装需要根据用途使用调试签名或正式分发渠道。 [构建与发行指南](docs/BUILD-RELEASE.md)

当前发行版本为 **v1.1.0**。版本标签对应发行源码。 [v1.1.0 Release](https://github.com/real-LEONEAST/UUHarmony/releases/tag/v1.1.0)

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `AppScope/`、`entry/` | 应用配置、ArkUI 界面、资源和 C/C++ 绑定 |
| `rust/` | 控制端核心与 WebRTC 适配 |
| `host-rust/` | 鸿蒙电脑被控端核心及其上游代码 |
| `scripts/build.cjs`、`hvigor/` | ARM64 构建入口与 DevEco 构建配置 |

## 许可

根目录提供 GNU GPL 第 3 版许可文本。各上游组件的源码来源、修改和许可条款见第三方声明。 [许可证](LICENSE) · [第三方声明](THIRD_PARTY_NOTICES.md)
