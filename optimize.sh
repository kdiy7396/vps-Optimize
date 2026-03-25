#!/usr/bin/env bash
# ==============================================================================
#  OCI Rocky Linux 9 — 节点优化脚本
#  项目地址: https://github.com/YOUR_USERNAME/oci-rocky9-optimize
#
#  一键安装命令:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci-rocky9-optimize/main/optimize.sh)"
#
#  可选参数（环境变量传入）:
#    SKIP_KERNEL=1   跳过内核升级（仅调优，不换内核）
#    SKIP_REBOOT=1   脚本结束后不自动重启（默认提示手动重启）
#    AUTO_REBOOT=1   优化完成后自动重启（无人值守部署用）
#
#  示例（跳过内核升级）:
#    SKIP_KERNEL=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci-rocky9-optimize/main/optimize.sh)"
# ==============================================================================

set -euo pipefail

# ---------- 运行时配置 ----------
SKIP_KERNEL="${SKIP_KERNEL:-0}"
SKIP_REBOOT="${SKIP_REBOOT:-0}"
AUTO_REBOOT="${AUTO_REBOOT:-0}"
LOGFILE="/var/log/oci-optimize.log"
SCRIPT_VERSION="1.2.0"
# --------------------------------

# tee 到日志，同时保留终端输出
exec > >(tee -a "$LOGFILE") 2>&1

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
success() { echo -e "${GREEN}${BOLD}✓ $*${NC}"; }

# ---------- 前置检查 ----------
[[ $EUID -ne 0 ]] && error "请以 root 身份运行，或使用: sudo bash -c \"\$(curl -fsSL URL)\""
[[ "$(uname -m)" != "x86_64" ]] && warn "非 x86_64 架构，部分优化可能不适用"

# 检测发行版
if ! grep -qi "rocky" /etc/os-release 2>/dev/null; then
  warn "非 Rocky Linux 系统，脚本针对 Rocky Linux 9 优化，继续执行可能有风险"
fi

OS_VER=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
ARCH=$(uname -m)
KERNEL_CURRENT=$(uname -r)

echo -e "${BOLD}"
cat << 'BANNER'
  ___   ____ ___    ___        _   _           _
 / _ \ / ___|_ _|  / _ \ _ __ | |_(_)_ __ ___ (_)_______
| | | | |    | |  | | | | '_ \| __| | '_ ` _ \| |_  / _ \
| |_| | |___ | |  | |_| | |_) | |_| | | | | | | |/ /  __/
 \___/ \____|___|  \___/| .__/ \__|_|_| |_| |_|_/___\___|
                        |_|    Rocky Linux 9 节点优化脚本
BANNER
echo -e "${NC}"

info "脚本版本: v${SCRIPT_VERSION}"
info "系统版本: Rocky Linux ${OS_VER} (${ARCH})"
info "当前内核: ${KERNEL_CURRENT}"
info "日志路径: ${LOGFILE}"
info "开始时间: $(date '+%F %T')"
[[ "$SKIP_KERNEL" == "1" ]] && warn "SKIP_KERNEL=1：跳过内核升级"


# ==============================================================================
# STEP 1 — /boot 分区清理
# ==============================================================================
step "STEP 1/6  /boot 分区清理"

BOOT_USAGE_BEFORE=$(df /boot | awk 'NR==2{print $5}' | tr -d '%')
info "/boot 清理前使用率: ${BOOT_USAGE_BEFORE}%"

# installonly_limit 先设为 2，防止 dnf 在后续操作中再装入旧内核
sed -i 's/^installonly_limit=.*/installonly_limit=2/' /etc/dnf/dnf.conf
grep -q '^installonly_limit' /etc/dnf/dnf.conf || echo 'installonly_limit=2' >> /etc/dnf/dnf.conf

# 找出所有 stock kernel（kernel / kernel-core），排除当前正在跑的
RUNNING_VER=$(uname -r | sed 's/\.x86_64$//')
INSTALLED_KERNELS=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V || true)

if [[ -n "$INSTALLED_KERNELS" ]]; then
  while IFS= read -r kver; do
    [[ "$kver" == "$RUNNING_VER" ]] && continue
    info "移除旧内核: $kver"
    dnf remove -y \
      "kernel-$kver" "kernel-core-$kver" \
      "kernel-modules-$kver" "kernel-modules-extra-$kver" \
      "kernel-devel-$kver" \
      2>/dev/null || true
  done <<< "$INSTALLED_KERNELS"
else
  info "无需清理旧内核"
fi

# 清理 kdump initramfs、旧 rescue img
rm -f /boot/initramfs-*.kdump.img 2>/dev/null || true
rm -f /boot/initramfs-0-rescue-*.img 2>/dev/null || true

# 清理 dnf 缓存
dnf clean all

BOOT_USAGE_AFTER=$(df /boot | awk 'NR==2{print $5}' | tr -d '%')
info "/boot 清理后使用率: ${BOOT_USAGE_AFTER}%"
success "/boot 清理完成（${BOOT_USAGE_BEFORE}% → ${BOOT_USAGE_AFTER}%）"


# ==============================================================================
# STEP 2 — 系统更新 & 工具包安装
# ==============================================================================
step "STEP 2/6  系统更新 & 工具包安装"

dnf update -y --nobest 2>/dev/null || dnf update -y

dnf install -y \
  epel-release \
  tuned \
  irqbalance \
  ethtool \
  conntrack-tools \
  nftables \
  net-tools \
  iproute \
  iproute-tc \
  wget curl \
  htop \
  lsof \
  2>/dev/null || true

systemctl enable --now tuned
tuned-adm profile throughput-performance
info "tuned profile → throughput-performance"

systemctl enable --now irqbalance
info "irqbalance 已启用"

success "工具包安装完成"


# ==============================================================================
# STEP 3 — ELRepo kernel-ml 安装（可跳过）
# ==============================================================================
step "STEP 3/6  ELRepo kernel-ml（mainline 内核）"

if [[ "$SKIP_KERNEL" == "1" ]]; then
  warn "已跳过内核升级（SKIP_KERNEL=1）"
else
  # 判断是否已经在跑 kernel-ml
  if uname -r | grep -q '\.elrepo$'; then
    info "当前已在运行 ELRepo kernel-ml: $(uname -r)，跳过安装"
  else
    info "安装 ELRepo 仓库..."
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null || true

    # 判断是否已添加 elrepo 仓库
    if ! rpm -q elrepo-release &>/dev/null; then
      dnf install -y \
        https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm \
        2>/dev/null || true
    fi

    # 检查能否连通 ELRepo（网络问题时给出提示，不中断脚本）
    if ! dnf --enablerepo=elrepo-kernel list available kernel-ml &>/dev/null; then
      warn "ELRepo 仓库暂时无法访问，跳过内核升级（可事后手动执行）"
      warn "  手动命令: dnf --enablerepo=elrepo-kernel install -y kernel-ml"
    else
      info "正在安装 kernel-ml，这可能需要几分钟..."
      dnf --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-modules

      # 获取新内核版本
      KML_VER=$(rpm -q kernel-ml --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)
      info "kernel-ml 版本: ${KML_VER}"

      # 将 kernel-ml 设为默认启动项
      GRUB_ENTRY=$(grubby --info=ALL 2>/dev/null \
        | awk -F'"' '/title=.*elrepo/{print $2}' | head -1 || true)

      if [[ -n "$GRUB_ENTRY" ]]; then
        grubby --set-default-index=0 2>/dev/null || true
        info "GRUB 默认内核 → kernel-ml"
      else
        # fallback: 按 vmlinuz 路径设置
        KML_VMLINUZ=$(ls /boot/vmlinuz-*elrepo* 2>/dev/null | sort -V | tail -1 || true)
        if [[ -n "$KML_VMLINUZ" ]]; then
          grubby --set-default "$KML_VMLINUZ"
          info "GRUB 默认内核 → $KML_VMLINUZ"
        fi
      fi

      # 安装完 kernel-ml 后，再清理一次 /boot（stock kernel）
      info "清理旧 stock 内核，释放 /boot 空间..."
      STOCK_KERNELS=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null \
        | grep -v 'ml\|elrepo' | sort -V || true)
      if [[ -n "$STOCK_KERNELS" ]]; then
        while IFS= read -r kver; do
          [[ "$kver" == "$RUNNING_VER" ]] && continue
          dnf remove -y "kernel-$kver" "kernel-core-$kver" \
            "kernel-modules-$kver" "kernel-modules-extra-$kver" 2>/dev/null || true
        done <<< "$STOCK_KERNELS"
      fi

      BOOT_USAGE_KML=$(df /boot | awk 'NR==2{print $5}' | tr -d '%')
      info "/boot 当前使用率: ${BOOT_USAGE_KML}%"
      success "kernel-ml 安装完成，重启后生效"
    fi
  fi
fi


# ==============================================================================
# STEP 4 — sysctl 内核网络调优
# ==============================================================================
step "STEP 4/6  sysctl 网络调优"

SYSCTL_FILE="/etc/sysctl.d/99-oci-optimize.conf"
cat > "$SYSCTL_FILE" << 'SYSCTL_EOF'
# ============================================================
#  OCI Rocky Linux 9 — 代理节点网络调优
#  由 oci-rocky9-optimize 脚本生成，请勿手动编辑
# ============================================================

# ----- IP 转发 -----
net.ipv4.ip_forward                     = 1
net.ipv4.conf.all.forwarding            = 1
net.ipv6.conf.all.forwarding            = 1

# ----- TCP 缓冲区（64 MB）-----
net.core.rmem_default                   = 262144
net.core.wmem_default                   = 262144
net.core.rmem_max                       = 67108864
net.core.wmem_max                       = 67108864
net.core.netdev_max_backlog             = 32768
net.core.somaxconn                      = 32768
net.core.optmem_max                     = 65536
net.ipv4.tcp_rmem                       = 4096 87380 67108864
net.ipv4.tcp_wmem                       = 4096 65536 67108864
net.ipv4.tcp_mem                        = 786432 1048576 26777216
net.ipv4.udp_rmem_min                   = 8192
net.ipv4.udp_wmem_min                   = 8192

# ----- BBR 拥塞控制 + FQ 队列 -----
net.core.default_qdisc                  = fq
net.ipv4.tcp_congestion_control         = bbr

# ----- TCP 性能 -----
net.ipv4.tcp_fastopen                   = 3
net.ipv4.tcp_slow_start_after_idle      = 0
net.ipv4.tcp_tw_reuse                   = 1
net.ipv4.tcp_fin_timeout                = 15
net.ipv4.tcp_keepalive_time             = 600
net.ipv4.tcp_keepalive_intvl            = 30
net.ipv4.tcp_keepalive_probes           = 5
net.ipv4.tcp_max_syn_backlog            = 8192
net.ipv4.tcp_max_tw_buckets             = 262144
net.ipv4.tcp_no_metrics_save            = 1
net.ipv4.tcp_mtu_probing                = 1
net.ipv4.tcp_timestamps                 = 1
net.ipv4.tcp_sack                       = 1
net.ipv4.tcp_dsack                      = 1
net.ipv4.tcp_fack                       = 0
net.ipv4.tcp_window_scaling             = 1
net.ipv4.tcp_adv_win_scale              = 1
net.ipv4.tcp_moderate_rcvbuf            = 1
net.ipv4.tcp_notsent_lowat              = 16384

# ----- ICMP / 路由安全 -----
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.conf.all.accept_redirects      = 0
net.ipv4.conf.default.accept_redirects  = 0
net.ipv6.conf.all.accept_redirects      = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1

# ----- 连接跟踪（高并发节点）-----
net.netfilter.nf_conntrack_max                      = 1048576
net.nf_conntrack_max                                = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established  = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait    = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait     = 30

# ----- IPv6（双栈）-----
net.ipv6.conf.all.disable_ipv6     = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra        = 2
net.ipv6.conf.default.accept_ra    = 2

# ----- 文件句柄 -----
fs.file-max                         = 1048576
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288

# ----- 内存 -----
vm.swappiness                       = 10
vm.dirty_ratio                      = 40
vm.dirty_background_ratio           = 10
vm.overcommit_memory                = 1

# ----- 内核安全 -----
kernel.dmesg_restrict               = 1
kernel.sysrq                        = 0
SYSCTL_EOF

# 加载 nf_conntrack 模块（否则 conntrack sysctl 报错）
modprobe nf_conntrack 2>/dev/null || true
# 确保重启后自动加载
echo 'nf_conntrack' > /etc/modules-load.d/nf_conntrack.conf

sysctl -p "$SYSCTL_FILE" 2>/dev/null || sysctl --system

# BBR 验证
if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  success "BBR 拥塞控制已启用 ✓"
else
  warn "当前内核版本可能不支持 BBR，重启到新内核后将自动生效"
fi

success "sysctl 调优完成 → $SYSCTL_FILE"


# ==============================================================================
# STEP 5 — 系统资源限制
# ==============================================================================
step "STEP 5/6  资源限制（ulimit）"

cat > /etc/security/limits.d/99-oci-optimize.conf << 'LIMITS_EOF'
# OCI 节点优化 — 文件描述符 & 进程数
*     soft  nofile  1048576
*     hard  nofile  1048576
*     soft  nproc   65536
*     hard  nproc   65536
root  soft  nofile  1048576
root  hard  nofile  1048576
root  soft  nproc   65536
root  hard  nproc   65536
LIMITS_EOF

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat > /etc/systemd/system.conf.d/99-oci-optimize.conf << 'SYSTEMD_EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65536
DefaultTasksMax=infinity
SYSTEMD_EOF

cat > /etc/systemd/user.conf.d/99-oci-optimize.conf << 'SYSTEMD_EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65536
SYSTEMD_EOF

systemctl daemon-reload
success "资源限制已设置（nofile=1048576, nproc=65536）"


# ==============================================================================
# STEP 6 — 网卡队列 & TXQ 优化
# ==============================================================================
step "STEP 6/6  网卡队列优化"

PRIMARY_NIC=$(ip -o link show \
  | awk -F': ' '{print $2}' \
  | grep -vE '^(lo|docker|virbr|tun|tap|dummy)' \
  | head -1)

if [[ -z "$PRIMARY_NIC" ]]; then
  warn "无法检测主网卡，跳过网卡优化"
else
  info "主网卡: $PRIMARY_NIC"

  ip link set "$PRIMARY_NIC" txqueuelen 10000 2>/dev/null || true

  for feat in gro gso tso rx tx; do
    ethtool -K "$PRIMARY_NIC" "$feat" on 2>/dev/null || true
  done
  info "GRO/GSO/TSO/RX/TX offload 已开启"

  MAX_RING=$(ethtool -g "$PRIMARY_NIC" 2>/dev/null \
    | awk '/^Pre-set/{getline; print $2}' | head -1 || echo "")
  if [[ -n "$MAX_RING" && "$MAX_RING" -gt 256 ]]; then
    ethtool -G "$PRIMARY_NIC" rx "$MAX_RING" tx "$MAX_RING" 2>/dev/null || true
    info "Ring Buffer → $MAX_RING"
  fi

  # fq 队列调度（配合 BBR）
  if command -v tc &>/dev/null; then
    tc qdisc replace dev "$PRIMARY_NIC" root fq 2>/dev/null || true
    info "tc qdisc → fq"
  fi

  # 持久化 txqueuelen（NetworkManager dispatcher）
  NM_DISP_DIR="/etc/NetworkManager/dispatcher.d"
  if [[ -d "$NM_DISP_DIR" ]]; then
    cat > "${NM_DISP_DIR}/99-txqueuelen" << DISP_EOF
#!/usr/bin/env bash
# 由 oci-rocky9-optimize 生成
IFACE="\$1"; EVENT="\$2"
[[ "\$EVENT" == "up" && "\$IFACE" == "${PRIMARY_NIC}" ]] \
  && ip link set "${PRIMARY_NIC}" txqueuelen 10000
DISP_EOF
    chmod +x "${NM_DISP_DIR}/99-txqueuelen"
    info "txqueuelen 持久化 → ${NM_DISP_DIR}/99-txqueuelen"
  fi

  success "网卡优化完成 ✓"
fi


# ==============================================================================
# EXTRA — IPv6 连通性检测
# ==============================================================================
echo ""
info ">>> [Extra] IPv6 连通性检测"

IPV6_ADDR=$(ip -6 addr show scope global 2>/dev/null \
  | awk '/inet6/{print $2}' | head -1 || true)

if [[ -n "$IPV6_ADDR" ]]; then
  info "全局 IPv6 地址: $IPV6_ADDR"
  if ping6 -c 2 -W 3 2606:4700:4700::1111 &>/dev/null 2>&1; then
    success "IPv6 外网连通 ✓"
  else
    warn "IPv6 无法 ping 外网，请检查 OCI 安全列表 / 防火墙规则"
  fi
else
  warn "未检测到全局 IPv6 地址"
  warn "请在 OCI 控制台：子网 → IPv6 前缀 → 分配，并在实例 VNIC 启用 IPv6"
fi


# ==============================================================================
# 完成汇总
# ==============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
cat << 'DONE'
╔══════════════════════════════════════════════════════════════╗
║              ✅  所有优化步骤已完成                          ║
╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

echo -e "${CYAN}── 验证命令 ──────────────────────────────────────────────────${NC}"
echo "  内核版本:    uname -r"
echo "  BBR 状态:    sysctl net.ipv4.tcp_congestion_control"
echo "  /boot 空间:  df -h /boot"
echo "  文件描述符:  ulimit -n"
echo "  连接跟踪:    sysctl net.netfilter.nf_conntrack_max"
echo "  日志:        cat $LOGFILE"
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"

# 重启处理
if [[ "$SKIP_REBOOT" == "1" ]]; then
  warn "SKIP_REBOOT=1：请在合适时间手动执行: reboot"
elif [[ "$AUTO_REBOOT" == "1" ]]; then
  info "AUTO_REBOOT=1：30 秒后自动重启... （Ctrl+C 取消）"
  sleep 30
  reboot
else
  echo ""
  echo -e "${YELLOW}⚠  内核参数及新内核需要重启后完全生效。${NC}"
  echo -e "${YELLOW}   准备好后请执行: ${BOLD}reboot${NC}"
fi
