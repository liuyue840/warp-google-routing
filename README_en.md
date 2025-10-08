# WARP Google Routing - WireGuard Edition

## Overview

This project provides a robust and efficient solution for selectively routing only Google traffic through Cloudflare's WARP network, while all other traffic from your server goes through the default network interface. This is achieved using WireGuard for a stable, low-overhead connection, `ipset` for efficient IP address management, and `iptables` for policy-based routing.

This script is designed for **Debian 12** but may be compatible with other Debian-based distributions like Ubuntu.

**Key Features:**

*   **Selective Google Routing:** Only traffic destined for Google's services (including Google Search, YouTube, Google Cloud, etc.) is routed through WARP.
*   **WireGuard-Based:** Utilizes WireGuard for a fast, modern, and secure VPN connection, which is more stable and has lower CPU usage than other methods.
*   **Automated Setup:** The script automates the entire process, including:
    *   Cleaning up previous WARP installations.
    *   Installing all necessary dependencies.
    *   Registering a new WARP account via the Cloudflare API.
    *   Configuring WireGuard, routing tables, and firewall rules.
    *   Setting up a systemd service for auto-starting on boot.
*   **Stable and Low-Maintenance:** Once set up, the solution is designed to be stable and requires minimal intervention.
*   **Comprehensive Management:** Includes scripts and commands to easily manage, test, and monitor the service.

## How It Works

1.  **WARP Account & WireGuard:** The script registers a new WARP account and creates a local WireGuard configuration (`wgcf.conf`) to connect to the WARP network.
2.  **IP Sets:** It creates an `ipset` named `google_ips` and populates it with a curated list of Google's global IP address ranges. This is much more efficient than using thousands of individual `iptables` rules.
3.  **Policy Routing:**
    *   An `iptables` rule in the `mangle` table marks all outgoing packets destined for the IPs in the `google_ips` set with a firewall mark (`200`).
    *   A policy routing rule (`ip rule`) directs all packets with this firewall mark to use a separate routing table (`warp`).
    *   The `warp` routing table has a single default route that sends all traffic through the `wgcf` WireGuard interface.
4.  **Systemd Service:** A `systemd` service (`warp-wg.service`) ensures that the WireGuard connection and all routing rules are automatically applied on system boot.

## Installation

You can install this solution with a single command.

### Quick Install

Run the following command as the `root` user on your Debian 12 server:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liuyue840/warp-google-routing/master/install.sh)"
```

The script will perform all necessary steps automatically.

### Manual Installation

1.  **Download the script:**
    ```bash
    wget https://raw.githubusercontent.com/liuyue840/warp-google-routing/master/install.sh
    ```
2.  **Make it executable:**
    ```bash
    chmod +x install.sh
    ```
3.  **Run the script:**
    ```bash
    ./install.sh
    ```

The script will execute and configure your system.

## Management Commands

Once installed, you can manage the service using standard `systemctl` commands.

*   **Check Service Status:**
    ```bash
    systemctl status warp-wg
    ```

*   **Restart the Service:**
    ```bash
    systemctl restart warp-wg
    ```

*   **Stop the Service:**
    ```bash
    systemctl stop warp-wg
    ```

*   **Start the Service:**
    ```bash
    systemctl start warp-wg
    ```

## Testing and Verification

You can verify that the routing is working correctly with the following tests.

1.  **Check Your Public IP (Should be your server's IP):**
    ```bash
    curl https://ip.sb
    ```

2.  **Check the IP for Google Traffic (Should be a Cloudflare IP):**
    The script does this automatically upon completion. You can also run it manually:
    ```bash
    curl -I https://www.google.com
    ```
    Look at the headers to see the connection details.

3.  **View WireGuard Status:**
    ```bash
    wg show wgcf
    ```
    This will show you the status of the WireGuard tunnel, including data transfer statistics and the latest handshake.

4.  **List Google IPs:**
    ```bash
    ipset list google_ips
    ```

5.  **Check Routing Rules:**
    ```bash
    ip rule list
    ```
    You should see a rule for `fwmark 200` pointing to the `warp` table.

## Files and Configuration

*   **WireGuard Configuration:** `/etc/wireguard/wgcf.conf`
*   **Google IP List:** `/etc/google-ips-wg.txt`
*   **IPSet Configuration:** `/etc/ipset-google.conf`
*   **Systemd Service:** `/etc/systemd/system/warp-wg.service`
*   **Start/Stop Scripts:**
    *   `/usr/local/bin/warp-wg-start.sh`
    *   `/usr/local/bin/warp-wg-stop.sh`

## Troubleshooting

*   **If Google is not accessible:**
    1.  Check the service status with `systemctl status warp-wg`.
    2.  Check the WireGuard status with `wg show wgcf`. Ensure there is a recent handshake.
    3.  Restart the service: `systemctl restart warp-wg`.
*   **If all traffic is going through WARP:**
    *   This is unlikely with this script. Check your `ip rule list` and `iptables -t mangle -L` to ensure the rules are correct.
*   **To completely uninstall:**
    Run the stop script, disable the service, and then delete the files listed above.
    ```bash
    /usr/local/bin/warp-wg-stop.sh
    systemctl disable warp-wg
    rm /etc/wireguard/wgcf.conf /etc/google-ips-wg.txt /etc/ipset-google.conf /etc/systemd/system/warp-wg.service /usr/local/bin/warp-wg-start.sh /usr/local/bin/warp-wg-stop.sh
    ```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.