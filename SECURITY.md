# Security Policy

## Reporting a Vulnerability

Because RemoteDesk provides remote control over macOS desktop sessions, security is taken seriously. If you discover a vulnerability or potential security flaw, please report it responsibly.

**Please DO NOT open a public GitHub issue.** Instead, please report security issues privately:
- **Email**: `security@alhamou.com` (or create a private GitHub Security Advisory via [Security > Advisories](../../security/advisories/new))
- **Response Time**: We aim to acknowledge receipt of vulnerabilities within 48 hours and provide a resolution timeline.

---

## Security Model & Threat Assessment

RemoteDesk is designed as a **high-performance, low-latency LAN tool for personal use between trusted Macs**. In v1.0.0, the application intentionally emphasizes minimal latency and zero third-party dependencies over transport-layer cryptographic overhead.

Users and developers must understand the following security realities:

### 1. Plaintext Network Transport (No Encryption)
- **Current State**: Network traffic between host and client is sent over unencrypted TCP sockets using Network.framework.
- **Risk**: Anyone with access to the same local network (or Wi-Fi subnet) can inspect packets using network analysis tools. Captured traffic includes video frames of the host display and keystrokes sent by the client.
- **Mitigation**: Do not transmit sensitive data (such as passwords, credit card numbers, or private keys) across untrusted networks. When connecting across untrusted networks or the internet, tunnel connections through **SSH (`ssh -L 8790:localhost:8790`)**, **WireGuard**, or **Tailscale**.

### 2. Unauthenticated Connections (No Pairing Model)
- **Current State**: The host accepts connections from any client that connects to port 8790 and sends a valid `hello` frame. There is no pre-shared key (PSK), password, PIN exchange, or "Accept/Deny" prompt on the host machine.
- **Risk**: Any device on the same local subnet can connect to an active host and immediately receive the desktop video feed.
- **Mitigation**: Only enable "Share This Mac" when actively in use on a trusted private network. Stop sharing when finished.

### 3. Remote Input Injection Privileges
- **Current State**: Connected clients have full input injection privileges via macOS `CGEvent` APIs. The host executes injected keyboard and mouse events using the system permissions granted under **System Settings → Privacy & Security → Accessibility**.
- **Risk**: An unauthenticated client on the LAN can execute arbitrary keystrokes, open Terminal, and execute commands under the privileges of the currently logged-in macOS user.
- **Mitigation**: Never leave a host session listening on a network accessible by untrusted users or devices.

### 4. Automatic Clipboard Synchronization
- **Current State**: The host and client automatically sync plaintext clipboard contents every 500ms (up to 1 MB).
- **Risk**: Copying sensitive data (such as passwords, API tokens, or 2FA codes) while RemoteDesk is connected will automatically broadcast that text to connected clients over the unencrypted network. Additionally, a connected client can overwrite the host's system clipboard without user confirmation (clipboard hijacking).
- **Mitigation**: Exercise caution when copying credentials during active sessions, or run with `--no-ui` / disable sharing when handling secrets.

---

## Safe Usage Guidelines

To maintain security while using RemoteDesk:
1. **Trusted Networks Only**: Run RemoteDesk exclusively on isolated private home or office LANs where all network devices are trusted.
2. **Never Use on Public Wi-Fi**: Never enable RemoteDesk on public, shared, or guest Wi-Fi networks (e.g., coffee shops, hotels, airports).
3. **Encrypted Tunnels**: For connections outside your home LAN, always route traffic through an encrypted tunnel:
   ```bash
   # Example: SSH local port forwarding from client to host
   ssh -N -L 8790:127.0.0.1:8790 user@remote-mac.local

   # Connect RemoteDesk client to local forward
   RemoteDesk --client --connect 127.0.0.1:8790
   ```
4. **Firewall Rules**: Keep the macOS Application Firewall enabled. Allow incoming connections to RemoteDesk only when intended.
