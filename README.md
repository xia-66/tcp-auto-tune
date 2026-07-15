# tcp-auto-tune

适用于 Debian / Ubuntu 代理节点的 TCP 自动调优脚本。

脚本会自动检测带宽、RTT、默认网卡，并根据机器实际情况配置 TCP 参数，适合 Xray、sing-box、Hysteria、Trojan、Shadowsocks 等代理节点使用。

## 功能

- 自动检测系统和内核
- 自动检测 BBR 支持
- 自动启用 BBR + fq
- 自动测速下载 / 上传带宽
- 自动测试 RTT
- 自动计算 TCP buffer
- 自动配置 sysctl TCP 参数
- 自动开启 MTU probing
- 自动提高文件句柄限制
- 自动识别默认出口网卡
- 自动设置上传限速，缓解 bufferbloat
- 自动创建 systemd 服务，保证限速重启后生效

## 支持系统

推荐：

- Debian 11
- Debian 12
- Ubuntu 20.04
- Ubuntu 22.04
- Ubuntu 24.04

要求：

- root 权限
- 内核支持 BBR

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xia-66/tcp-auto-tune/main/tcp-auto-tune.sh)
