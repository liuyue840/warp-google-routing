#!/bin/bash

#############################################
# WARP + Google选择性路由 - WireGuard方案
# 版本: v5.0 Final
# 适用: Debian 12 (可能兼容其他Debian/Ubuntu)
# 功能: 仅Google流量走WARP，其他直连
# 特点: 稳定、低CPU占用、无daemon问题
# 作者: 基于Cloudflare WARP API
#############################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#============================================
# 函数定义
#============================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用root用户运行此脚本${NC}"
        exit 1
    fi
}

cleanup_old_warp() {
    echo -e "${YELLOW}[1/7] 清理旧的WARP配置...${NC}"
    
    # 停止并卸载官方WARP客户端
    systemctl stop warp-svc 2>/dev/null || true
    systemctl disable warp-svc 2>/dev/null || true
    systemctl mask warp-svc 2>/dev/null || true
    killall -9 warp-svc warp-dex boringtun-cli warp-cli 2>/dev/null || true
    sleep 2
    
    apt remove --purge cloudflare-warp -y 2>/dev/null || true
    apt remove --purge redsocks -y 2>/dev/null || true
    apt autoremove -y
    
    # 删除数据和配置
    rm -rf /var/lib/cloudflare-warp
    rm -rf /etc/cloudflare-warp
    rm -rf /opt/cloudflare-warp
    rm -rf ~/.cloudflare-warp
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    # 清理网络配置
    ip link del CloudflareWARP 2>/dev/null || true
    ip link del wgcf 2>/dev/null || true
    
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    
    ipset destroy google_ips 2>/dev/null || true
    
    ip rule del fwmark 100 2>/dev/null || true
    ip rule del fwmark 200 2>/dev/null || true
    
    # 删除旧脚本
    rm -f /usr/local/bin/warp-*.sh 2>/dev/null || true
    rm -f /etc/systemd/system/warp-*.service 2>/dev/null || true
    rm -f /etc/cron.d/warp-* 2>/dev/null || true
    rm -f /etc/cron.hourly/update-google-ips 2>/dev/null || true
    rm -f /etc/cron.daily/update-google-ips 2>/dev/null || true
    rm -f /etc/cron.monthly/update-google-ips 2>/dev/null || true
    
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ 清理完成${NC}"
}

install_dependencies() {
    echo -e "${YELLOW}[2/7] 安装依赖包...${NC}"
    
    apt update
    apt install -y wireguard-tools curl jq iptables ipset \
        iptables-persistent iproute2 dnsutils
    
    echo -e "${GREEN}✓ 依赖已安装${NC}"
}

configure_dns() {
    echo -e "${YELLOW}[3/7] 配置DNS（防止解析循环）...${NC}"
    
    # 确保DNS稳定
    if [ -f /etc/resolvconf/resolv.conf.d/base ]; then
        cat > /etc/resolvconf/resolv.conf.d/base << 'BASEDNS'
nameserver 8.8.8.8
nameserver 8.8.4.4
BASEDNS
    fi
    
    cat > /etc/resolv.conf << 'RESOLVCONF'
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:2
RESOLVCONF
    
    echo -e "${GREEN}✓ DNS已配置${NC}"
}

register_warp() {
    echo -e "${YELLOW}[4/7] 注册WARP账户...${NC}"
    
    # 生成WireGuard密钥对
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    
    echo "  密钥对已生成"
    
    # 向Cloudflare API注册
    echo "  正在注册..."
    RESPONSE=$(curl -s --max-time 15 -X POST https://api.cloudflareclient.com/v0a2158/reg \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$PUBLIC_KEY\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"type\":\"Android\",\"model\":\"PC\",\"locale\":\"en_US\"}")
    
    # 解析响应
    CLIENT_ID=$(echo "$RESPONSE" | jq -r '.config.client_id // empty')
    WARP_IPV4=$(echo "$RESPONSE" | jq -r '.config.interface.addresses.v4 // empty')
    ENDPOINT_HOST=$(echo "$RESPONSE" | jq -r '.config.peers[0].endpoint.host // empty')
    
    if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
        echo -e "${RED}❌ WARP注册失败${NC}"
        echo "API响应: $RESPONSE"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 注册成功${NC}"
    echo "  Client ID: $CLIENT_ID"
    echo "  WARP IP: $WARP_IPV4"
    
    # 解析endpoint IP（避免DNS问题）
    if [[ "$ENDPOINT_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ENDPOINT_IP="$ENDPOINT_HOST"
    else
        ENDPOINT_IP=$(dig +short "$ENDPOINT_HOST" A | head -1)
        if [ -z "$ENDPOINT_IP" ]; then
            echo -e "${YELLOW}  DNS解析失败，使用备用IP${NC}"
            ENDPOINT_IP="162.159.193.1"
        fi
    fi
    
    echo "  Endpoint: $ENDPOINT_IP:2408"
    
    # 创建WireGuard配置
    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wgcf.conf << WGCONF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $WARP_IPV4/32
DNS = 1.1.1.1
MTU = 1280
Table = 200

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = $ENDPOINT_IP:2408
PersistentKeepalive = 25
WGCONF
    
    chmod 600 /etc/wireguard/wgcf.conf
    
    echo -e "${GREEN}✓ WireGuard配置已创建${NC}"
}

setup_routing_tables() {
    echo -e "${YELLOW}[5/7] 配置路由表...${NC}"
    
    # 确保iproute2配置目录存在
    mkdir -p /etc/iproute2
    
    # 创建路由表文件（如果不存在）
    if [ ! -f /etc/iproute2/rt_tables ]; then
        cat > /etc/iproute2/rt_tables << 'RTTABLES'
255	local
254	main
253	default
0	unspec
RTTABLES
    fi
    
    # 添加warp路由表
    if ! grep -q "200 warp" /etc/iproute2/rt_tables; then
        echo "200 warp" >> /etc/iproute2/rt_tables
    fi
    
    echo -e "${GREEN}✓ 路由表已配置${NC}"
}

start_wireguard() {
    echo -e "${YELLOW}[6/7] 启动WireGuard...${NC}"
    
    # 清理可能存在的旧接口
    wg-quick down wgcf 2>/dev/null || true
    sleep 1
    
    # 启动WireGuard
    if wg-quick up wgcf; then
        echo -e "${GREEN}✓ WireGuard已启动${NC}"
    else
        echo -e "${RED}❌ WireGuard启动失败${NC}"
        exit 1
    fi
    
    sleep 2
    
    # 验证接口
    if ! ip link show wgcf &>/dev/null; then
        echo -e "${RED}❌ wgcf接口不存在${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ wgcf接口已创建${NC}"
}

configure_google_routing() {
    echo -e "${YELLOW}[7/7] 配置Google选择性路由...${NC}"
    
    # 创建Google IP列表（覆盖全球主要数据中心）
    cat > /etc/google-ips-wg.txt << 'IPLIST'
# Google全球IP段
142.250.0.0/15
142.251.0.0/16
172.217.0.0/16
173.194.0.0/16
216.58.192.0/19
216.239.32.0/19
74.125.0.0/16

# Google Cloud
34.64.0.0/10
35.184.0.0/13

# Google DNS
8.8.8.0/24
8.8.4.0/24

# YouTube
208.65.152.0/22
208.117.224.0/19
IPLIST
    
    # 创建ipset
    ipset create google_ips hash:net maxelem 1000000 -exist
    ipset flush google_ips
    
    # 加载IP段
    LOADED=0
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        if ipset add google_ips "$line" -exist 2>/dev/null; then
            LOADED=$((LOADED + 1))
        fi
    done < /etc/google-ips-wg.txt
    
    echo "  已加载 $LOADED 个Google IP段"
    
    # 保存ipset配置
    ipset save google_ips > /etc/ipset-google.conf
    
    # 配置策略路由
    ip rule add fwmark 200 table warp prio 200 2>/dev/null || true
    ip route add default dev wgcf table warp 2>/dev/null || true
    
    # 配置iptables标记
    iptables -t mangle -N GOOGLE_MARK 2>/dev/null || iptables -t mangle -F GOOGLE_MARK
    iptables -t mangle -A GOOGLE_MARK -m set --match-set google_ips dst -j MARK --set-mark 200
    iptables -t mangle -D OUTPUT -j GOOGLE_MARK 2>/dev/null || true
    iptables -t mangle -A OUTPUT -j GOOGLE_MARK
    
    # 保存iptables规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    fi
    
    echo -e "${GREEN}✓ 路由规则已配置${NC}"
}

create_startup_script() {
    echo -e "${YELLOW}创建开机启动脚本...${NC}"
    
    # 启动脚本
    cat > /usr/local/bin/warp-wg-start.sh << 'STARTSCRIPT'
#!/bin/bash
# WARP WireGuard启动脚本

# 等待网络
sleep 5

# 启动WireGuard
wg-quick up wgcf 2>/dev/null || true
sleep 2

# 恢复ipset
if [ -f /etc/ipset-google.conf ]; then
    ipset restore < /etc/ipset-google.conf 2>/dev/null || true
fi

# 配置策略路由
ip rule add fwmark 200 table warp prio 200 2>/dev/null || true
ip route add default dev wgcf table warp 2>/dev/null || true

# 配置iptables
iptables -t mangle -N GOOGLE_MARK 2>/dev/null || iptables -t mangle -F GOOGLE_MARK
iptables -t mangle -A GOOGLE_MARK -m set --match-set google_ips dst -j MARK --set-mark 200
iptables -t mangle -D OUTPUT -j GOOGLE_MARK 2>/dev/null || true
iptables -t mangle -A OUTPUT -j GOOGLE_MARK
STARTSCRIPT
    
    chmod +x /usr/local/bin/warp-wg-start.sh
    
    # 停止脚本
    cat > /usr/local/bin/warp-wg-stop.sh << 'STOPSCRIPT'
#!/bin/bash
# WARP WireGuard停止脚本

# 清理iptables
iptables -t mangle -D OUTPUT -j GOOGLE_MARK 2>/dev/null || true
iptables -t mangle -F GOOGLE_MARK 2>/dev/null || true
iptables -t mangle -X GOOGLE_MARK 2>/dev/null || true

# 清理路由
ip rule del fwmark 200 2>/dev/null || true
ip route del default dev wgcf table warp 2>/dev/null || true

# 停止WireGuard
wg-quick down wgcf 2>/dev/null || true

# 清理ipset
ipset destroy google_ips 2>/dev/null || true
STOPSCRIPT
    
    chmod +x /usr/local/bin/warp-wg-stop.sh
    
    # 创建systemd服务
    cat > /etc/systemd/system/warp-wg.service << 'WGSVC'
[Unit]
Description=WARP WireGuard for Google Traffic
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-wg-start.sh
ExecStop=/usr/local/bin/warp-wg-stop.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
WGSVC
    
    systemctl daemon-reload
    systemctl enable warp-wg.service
    
    echo -e "${GREEN}✓ 开机启动已配置${NC}"
}

show_status() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ 部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    echo -e "${BLUE}流量路由配置：${NC}"
    echo "  📥 进站流量 (SSH等) → 直连"
    echo "  📤 Google服务流量    → WARP"
    echo "  📤 其他流量          → 直连"
    echo ""
    
    echo -e "${BLUE}WireGuard状态：${NC}"
    wg show wgcf 2>/dev/null || echo "  等待连接建立..."
    echo ""
    
    echo -e "${BLUE}接口信息：${NC}"
    ip addr show wgcf | grep -E "inet|state"
    echo ""
    
    echo -e "${BLUE}路由规则：${NC}"
    ip rule list | grep -E "200|warp" || echo "  未找到路由规则"
    echo ""
    
    echo -e "${BLUE}Google IP段数量：${NC}"
    echo "  $(ipset list google_ips 2>/dev/null | grep -c '^[0-9]') 个"
    echo ""
}

run_tests() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}运行连接测试${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    echo -e "${BLUE}测试1: 访问Google (应走WARP)${NC}"
    timeout 10 curl -I https://www.google.com 2>&1 | head -3 || echo "  超时或失败"
    echo ""
    
    echo -e "${BLUE}测试2: 访问其他网站 (应显示VPS IP)${NC}"
    VPS_IP=$(timeout 10 curl -s https://ip.sb 2>/dev/null || echo "获取失败")
    echo "  VPS IP: $VPS_IP"
    echo ""
    
    echo -e "${BLUE}测试3: WireGuard流量统计${NC}"
    sleep 3
    wg show wgcf | grep -E "transfer|handshake" || echo "  等待握手..."
    echo ""
}

show_usage() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}使用说明${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo -e "${BLUE}管理命令：${NC}"
    echo "  systemctl status warp-wg        # 查看服务状态"
    echo "  systemctl restart warp-wg       # 重启服务"
    echo "  systemctl stop warp-wg          # 停止服务"
    echo "  /usr/local/bin/warp-wg-stop.sh  # 手动停止"
    echo ""
    echo -e "${BLUE}查看状态：${NC}"
    echo "  wg show wgcf                    # WireGuard状态"
    echo "  ip -s link show wgcf            # 流量统计"
    echo "  ipset list google_ips           # Google IP列表"
    echo "  ip rule list                    # 路由规则"
    echo ""
    echo -e "${BLUE}测试命令：${NC}"
    echo "  curl -I https://www.google.com  # 测试Google访问"
    echo "  curl https://ip.sb               # 查看出口IP"
    echo "  ping -c 3 8.8.8.8                # 测试连通性"
    echo ""
    echo -e "${GREEN}完成！享受稳定的WARP服务！${NC}"
    echo ""
}

#============================================
# 主程序
#============================================

main() {
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  WARP + Google路由 WireGuard方案      ║${NC}"
    echo -e "${BLUE}║  版本: v5.0 Final                      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    cleanup_old_warp
    install_dependencies
    configure_dns
    setup_routing_tables
    register_warp
    start_wireguard
    configure_google_routing
    create_startup_script
    show_status
    run_tests
    show_usage
}

# 执行主程序
main