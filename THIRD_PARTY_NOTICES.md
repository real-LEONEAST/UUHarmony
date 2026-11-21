# 第三方声明

UUHarmony v1.0.63 包含对下列上游组件的 HarmonyOS 移植和本地修改。此快照整理于 2026-11-21。

| 组件 | 许可及来源 |
| --- | --- |
| Linux UU 远控协议与代码 | 控制端以 [VallierDev/uu-remote-linux 的固定版本](https://github.com/VallierDev/uu-remote-linux/tree/6bf05a6361e58dbeec5846f044d234bed04fcf02) 为协议与代码来源之一。控制端 Cargo 清单标注 GPL-3.0-only。 |
| 鸿蒙被控端 | 来源包含 [uu-remote-linux 的 HarmonyOS 移植](https://github.com/VallierDev/uu-remote-linux/pull/155) 及其 [固定版本](https://github.com/wannacu/uu-remote-linux/tree/4342b612af648f67c380ac90595fe1329cbb611a)。本目录包含用于当前工程的修改。上游声明为 GPL-3.0-or-later，许可保留在 `host-rust/LICENSE`。 |
| WebRTC for Rust | `rust/vendor/` 和 `host-rust/vendor/` 中的本地补丁保留原有 MIT／Apache-2.0 许可、补丁说明和锁定的依赖。DTLS 子目录里的示例证书和单元测试密钥是公开测试夹具，仅供示例或测试使用。 |
| Opus 1.5.2 | 源码和 BSD 许可位于 `entry/src/main/cpp/vendor/opus/`。 |
| xterm.js 6.0.0、fit 0.11.0 和 serialize 0.14.0 | MIT 许可与 npm 包版本、哈希和下载地址列在 `entry/src/main/resources/rawfile/terminal/vendor/NOTICE.json`。对应上游源码见 [xterm.js 6.0.0](https://github.com/xtermjs/xterm.js/tree/6.0.0)。 |
| NVENC 头文件 | 保留在 `host-rust/vendor/ffnvcodec/`，头文件内附 NVIDIA 许可。 |

网易 UU 远程和 HarmonyOS 的名称用于说明兼容性和目标平台。
