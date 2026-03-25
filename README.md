# oci-rocky9-optimize

Oracle Cloud 免费实例（AMD x86_64）+ Rocky Linux 9 一键优化脚本，专为代理节点场景设计。

## 功能

| 模块 | 内容 |
|---|---|
| `/boot` 清理 | 删除旧内核、清理 kdump initramfs，`installonly_limit=2` 防复发 |
| 系统更新 | `dnf update` + tuned / irqbalance / ethtool 等工具 |
| **kernel-ml** | 通过 ELRepo 安装 mainline 内核，支持更新网络栈 |
| sysctl 调优 | BBR + fq、64MB TCP 缓冲区、高并发连接跟踪、IPv4/IPv6 双栈转发 |
| 资源限制 | `nofile=1048576`，通过 `limits.conf` + systemd 双重生效 |
| 网卡优化 | txqueuelen=10000、GRO/GSO/TSO offload、Ring Buffer 最大化 |
| IPv6 检测 | 自动验证全局 IPv6 地址及外网连通性 |

## 快速开始

```bash
# 标准安装（含 kernel-ml 升级）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci-rocky9-optimize/main/optimize.sh)"
```

```bash
# 跳过内核升级（仅网络调优）
SKIP_KERNEL=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci-rocky9-optimize/main/optimize.sh)"
```

```bash
# 无人值守部署（自动重启）
AUTO_REBOOT=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci-rocky9-optimize/main/optimize.sh)"
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SKIP_KERNEL` | `0` | `1` = 跳过 ELRepo kernel-ml 安装 |
| `SKIP_REBOOT` | `0` | `1` = 脚本结束后不提示重启 |
| `AUTO_REBOOT` | `0` | `1` = 30 秒后自动重启（适合 CI/无人值守）|

## 重启后验证

```bash
uname -r                                    # 应显示 *elrepo* 内核
sysctl net.ipv4.tcp_congestion_control      # 应为 bbr
sysctl net.core.default_qdisc              # 应为 fq
df -h /boot                                 # 确认空间释放
ulimit -n                                   # 应为 1048576
```

## 关于 BBR 版本

- 本脚本安装的 ELRepo **kernel-ml** 当前包含 **BBR v1**（Linux 主线版本）
- BBR v3 目前仍未合并进 Linux 主线，需手动编译 Google BBR v3 分支才能使用
- BBR v1 + fq + 本脚本的 sysctl 调优，对代理节点场景已足够

## 日志

```bash
cat /var/log/oci-optimize.log
```

## 适用环境

- Oracle Cloud Free Tier — AMD x86_64（E2.1.Micro）
- Rocky Linux 9.x
- 需要 root 权限
