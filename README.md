# UUHarmony

UUHarmony 是面向 HarmonyOS 手机和平板、以及鸿蒙电脑的非官方远程桌面项目。它提供自有设备列表、远程桌面、文件传输和鸿蒙 PC 的屏幕共享。远程连接和设备管理依赖网易 UU 远程服务。

本源码快照对应 v1.0.63。项目与网易 UU 远程、华为无官方隶属关系。

## 源码结构

| 路径 | 内容 |
| --- | --- |
| `AppScope/`、`entry/` | HarmonyOS 应用、ArkUI 页面、资源和 C/C++ 绑定 |
| `rust/` | 控制端 Rust 核心及所用 WebRTC 补丁 |
| `host-rust/` | 鸿蒙 PC 被控端的 Rust 源码及其上游依赖 |
| `hvigor/`、`scripts/build.cjs` | ARM64 构建配置和入口 |
| `build-profile.example.json5` | 无签名的项目配置模板 |

## 构建 ARM64 HAP

在 Windows 上使用带 HarmonyOS API 26、Native SDK 和 OHPM 的 DevEco Studio，准备 Node.js 和带 `aarch64-unknown-linux-ohos` 目标的 Rust 工具链。从项目目录运行以下命令。

```powershell
rustup target add aarch64-unknown-linux-ohos
$env:DEVECO_HOME = 'C:/DevEco Studio'
node scripts/build.cjs all
```

把 `DEVECO_HOME` 改成自己的 DevEco Studio 安装目录。Cargo 需要在 PATH 上，也可通过 `CARGO` 指定可执行文件。初次构建通常需要下载锁定的 Cargo 和 OHPM 依赖。脚本也支持分开执行 `native` 和 `hap`，并接受 `--offline` 来让 Cargo 使用已有缓存。

首次构建会从模板生成本地 `build-profile.json5`。默认产物是 `entry/build/default/outputs/default/entry-default-unsigned.hap`。真机安装时，在 DevEco Studio 中为自己的设备配置签名。覆盖安装需要沿用设备上现有应用的签名身份。

## 许可与来源

许可文本和第三方来源见 [LICENSE](LICENSE) 与 [第三方声明](THIRD_PARTY_NOTICES.md)。开发者应在本地保存签名配置与调试设备资料。
