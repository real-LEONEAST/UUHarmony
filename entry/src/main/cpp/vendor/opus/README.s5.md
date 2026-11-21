# Pinned libopus source

- Version: **1.5.2**, official unmodified release source.
- Release and authoritative checksum: <https://opus-codec.org/release/stable/2024/04/12/libopus-1_5_2.html>
- Download: <https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz>
- SHA256: `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1`
- Verification: archive SHA256 matched the release checksum before extraction on 2026-11-03.
- Archive is retained as `opus-1.5.2.tar.gz`; extracted tree is `opus-1.5.2/`.
- Copyright and BSD conditions remain verbatim in `opus-1.5.2/COPYING`; upstream source file copyright notices are retained. Binary distributions must reproduce that notice and disclaimer in accompanying materials.
- Integration uses portable C with target intrinsics, custom modes, DRED and OSCE disabled. No FFmpeg, SDL, executable codec helper, or system Opus decoder is needed.
- `scripts/s5cd-audio-vendor.sh` downloads and verifies the same pinned archive. The downloader permits an unavailable certificate-revocation server to be skipped (`--ssl-revoke-best-effort`); HTTPS certificate chain validation remains enabled and the independently published fixed SHA256 is mandatory.
