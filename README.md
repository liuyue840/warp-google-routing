# WARP Google Routing - WireGuard 版

## 概述

该项目提供了一个强大而高效的解决方案，可选择性地仅将 Google 流量通过 Cloudflare 的 WARP 网络进行路由，而服务器的所有其他流量则通过默认网络接口。这是通过使用 WireGuard 实现稳定、低开销的连接，使用 `ipset` 进行高效的 IP 地址管理，以及使用 `iptables` 进行策略路由来实现的。

该脚本专为 **Debian 12** 设计，但可能与其他基于 Debian 的发行版（如 Ubuntu）兼容。

**主要特点：**

*   **选择性 Google 路由：** 只有发往 Google 服务（包括 Google 搜索、YouTube、Google Cloud 等）的流量才会通过 WARP 进行路由。
*   **基于 WireGuard：** 利用 WireGuard 实现快速、现代且安全的 VPN 连接，比其他方法更稳定，CPU 使用率更低。
*   **自动化设置：** 该脚本可自动执行整个过程，包括：
    *   清理以前的 WARP 安装。
    *   安装所有必需的依赖项。
    *   通过 Cloudflare API 注册新的 WARP 帐户。
    *   配置 WireGuard、路由表和防火墙规则。
    *   设置 systemd 服务以在启动时自动启动。
*   **稳定且低维护：** 一旦设置，该解决方案旨在保持稳定，并且需要最少的干预。
*   **全面的管理：** 包括用于轻松管理、测试和监控服务的脚本和命令。

## 工作原理

1.  **WARP 帐户和 WireGuard：** 该脚本注册一个新的 WARP 帐户，并创建一个本地 WireGuard 配置（`wgcf.conf`）以连接到 WARP 网络。
2.  **IP 集：** 它创建一个名为 `google_ips` 的 `ipset`，并使用精选的 Google 全球 IP 地址范围列表填充它。这比使用数千个单独的 `iptables` 规则要高效得多。
3.  **策略路由：**
    *   `mangle` 表中的 `iptables` 规则会使用防火墙标记（`200`）标记所有发往 `google_ips` 集中 IP 的传出数据包。
    *   策略路由规则（`ip rule`）会指示所有带有此防火墙标记的数据包使用单独的路由表（`warp`）。
    *   `warp` 路由表有一个单一的默认路由，可将所有流量通过 `wgcf` WireGuard 接口发送。
4.  **Systemd 服务：** `systemd` 服务（`warp-wg.service`）可确保 WireGuard 连接和所有路由规则在系统启动时自动应用。

## 安装

您可以使用单个命令安装此解决方案。

### 快速安装

在您的 Debian 12 服务器上以 `root` 用户身份运行以下命令：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liuyue840/warp-google-routing/master/install.sh)"
```

该脚本将自动执行所有必要的步骤。

### 手动安装

1.  **下载脚本：**
    ```bash
    wget https://raw.githubusercontent.com/liuyue840/warp-google-routing/master/install.sh
    ```
2.  **使其可执行：**
    ```bash
    chmod +x install.sh
    ```
3.  **运行脚本：**
    ```bash
    ./install.sh
    ```

该脚本将执行并配置您的系统。

## 管理命令

安装后，您可以使用标准的 `systemctl` 命令来管理服务。

*   **检查服务状态：**
    ```bash
    systemctl status warp-wg
    ```

*   **重新启动服务：**
    ```bash
    systemctl restart warp-wg
    ```

*   **停止服务：**
    ```bash
    systemctl stop warp-wg
    ```

*   **启动服务：**
    ```bash
    systemctl start warp-wg
    ```

## 测试和验证

您可以使用以下测试来验证路由是否正常工作。

1.  **检查您的公共 IP（应为您的服务器的 IP）：**
    ```bash
    curl https://ip.sb
    ```

2.  **检查 Google 流量的 IP（应为 Cloudflare IP）：**
    该脚本在完成后会自动执行此操作。您也可以手动运行它：
    ```bash
    curl -I https://www.google.com
    ```
    查看标题以查看连接详细信息。

3.  **查看 WireGuard 状态：**
    ```bash
    wg show wgcf
    ```
    这将向您显示 WireGuard 隧道的状态，包括数据传输统计信息和最新的握手。

4.  **列出 Google IP：**
    ```bash
    ipset list google_ips
    ```

5.  **检查路由规则：**
    ```bash
    ip rule list
    ```
    您应该会看到一个 `fwmark 200` 指向 `warp` 表的规则。

## 文件和配置

*   **WireGuard 配置：** `/etc/wireguard/wgcf.conf`
*   **Google IP 列表：** `/etc/google-ips-wg.txt`
*   **IPSet 配置：** `/etc/ipset-google.conf`
*   **Systemd 服务：** `/etc/systemd/system/warp-wg.service`
*   **启动/停止脚本：**
    *   `/usr/local/bin/warp-wg-start.sh`
    *   `/usr/local/bin/warp-wg-stop.sh`

## 故障排除

*   **如果无法访问 Google：**
    1.  使用 `systemctl status warp-wg` 检查服务状态。
    2.  使用 `wg show wgcf` 检查 WireGuard 状态。确保有最近的握手。
    3.  重新启动服务：`systemctl restart warp-wg`。
*   **如果所有流量都通过 WARP：**
    *   使用此脚本不太可能出现这种情况。检查您的 `ip rule list` 和 `iptables -t mangle -L` 以确保规则正确。
*   **要完全卸载：**
    运行停止脚本，禁用服务，然后删除上面列出的文件。
    ```bash
    /usr/local/bin/warp-wg-stop.sh
    systemctl disable warp-wg
    rm /etc/wireguard/wgcf.conf /etc/google-ips-wg.txt /etc/ipset-google.conf /etc/systemd/system/warp-wg.service /usr/local/bin/warp-wg-start.sh /usr/local/bin/warp-wg-stop.sh
    ```

## 许可证

该项目根据 MIT 许可证获得许可。有关详细信息，请参阅 [LICENSE](LICENSE) 文件。