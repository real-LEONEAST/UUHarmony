# 构建与发行

当前 `main` 支持 Windows 上的一键 ARM64 Release 构建。应用版本来自 DevEco 生成的包清单，文件名随版本更新。

## 环境

- 安装 DevEco Studio 26.0.0 Release、配套的 HarmonyOS API 26 SDK、Native SDK 和 OHPM。 [华为开发套件版本](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/overview-allversion/)
- 准备 Node.js 和可用的 `cargo`、`rustup`。Cargo 可从 PATH 查找，也可通过 `CARGO` 指定可执行文件。
- 在干净的源码副本中执行 Release 构建。脚本会从 `build-profile.example.json5` 创建无签名配置。已有本地签名配置时，脚本会停止并保留该文件，另用一份干净源码即可构建。

## 本地 Release

```powershell
rustup target add aarch64-unknown-linux-ohos
$env:DEVECO_HOME = 'C:/DevEco Studio'
node scripts/build.cjs release
```

将示例目录替换为本机 DevEco Studio 安装目录。脚本使用 `Cargo.lock` 中的依赖版本，按 Release 模式编译 Rust、C/C++ 和 ArkTS，并在编译原生库时重映射本机源码和依赖目录。首次构建需要准备相应的工具与依赖缓存。若 OHPM 提示 `SymLink Dir Failed`，请使用具备创建符号链接权限的构建进程。

已有 Cargo 缓存时可运行 `node scripts/build.cjs release --offline`。`--offline` 作用于 Cargo，OHPM 和 Hvigor 仍按各自配置使用依赖缓存。

v1.1.0 的本地输出如下。

```text
.build/release/
  UUHarmony-v1.1.0.hap
  UUHarmony-v1.1.0.app
```

控制端和鸿蒙电脑被控端的原生库会随界面一起打进同一个 HAP，供手机、平板和鸿蒙电脑使用。APP 封装这份应用的 HAP，供华为发布流程处理。

可以用 PowerShell 记录文件校验值。

```powershell
Get-ChildItem .build/release -File | Get-FileHash -Algorithm SHA256
```

调试构建继续使用 `node scripts/build.cjs all`，也可先执行 `native` 再执行 `hap`。切回调试构建时运行 `all` 可重新生成调试模式的原生库。

## 安装和分发

| 用途 | 方式 |
| --- | --- |
| 自有设备调试 | 在 DevEco Studio 使用自己的调试证书及调试 Profile，登记测试设备。覆盖安装时保持应用标识与签名身份一致。 |
| 邀请测试或正式发行 | 使用 Release `.app`，按 DevEco Studio 的 **Upload Product** 流程配置发布签名，再走华为邀请测试或应用市场分发。IDE 从项目的 `build/outputs/default/` 选择原始 APP。 |

未签名 HAP 需要通过系统认可的签名和相应安装方式。发布 Profile 的调试设备列表为空。正式分发前，在目标手机和 PC 上验证安装与主要功能，并核对下载目录、持久文件访问等权限能否授权。 [华为发布指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-publish-app/) · [Profile 说明](https://developer.huawei.com/consumer/cn/doc/app/agc-help-profile-overview-0000002283260125/) · [邀请测试](https://developer.huawei.com/consumer/cn/doc/app/agc-help-invite-test-overview-0000002287701773/)

签名密钥、证书配置、调试设备清单、构建输出和测试资料应保管在本地。GitHub 的版本标签用于记录源码版本。
