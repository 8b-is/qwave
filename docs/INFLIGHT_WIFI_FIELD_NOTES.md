# In-Flight Wi-Fi Field Notes & Zero-Float `p/q` Link Architecture (`DeltaWiFi.com`)

**Captured Live Airborne · 2026-11-03**
- **Flight 1 (Transpacific Widebody)**: **Delta Air Lines `DAL120`** (`RJTT` Tokyo Haneda → `KMSP` Minneapolis–Saint Paul) · **Airbus A350-900 (`N510DN`)** · Cruise `39,981 ft` (`505 kts`)
- **Flight 2 (Domestic Regional Jet)**: **Delta Air Lines `4965`** (`KMSP` Minneapolis–Saint Paul → `KORF` Norfolk) · **Bombardier CRJ-900 (`N292PQ`)** · Cruise `30,419–32,126 ft` (`447–457 kts`)

---

## 1. Two Distinct Cabin Network Architectures Behind One SSID (`DeltaWiFi.com`)

Even though both aircraft broadcast the open 5 GHz SSID **`DeltaWiFi.com`**, their cabin routers, DHCP options, DNS servers, and onboard API schemas differ significantly:

| Property | Widebody Architecture (`DAL120` · Airbus A350 `N510DN`) | Regional / Narrowbody Architecture (`Delta 4965` · CRJ-900 `N292PQ`) |
|---|---|---|
| **SSID & Security** | `DeltaWiFi.com` (Open, 5 GHz `5785 MHz` Ch 157) | `DeltaWiFi.com` (Open, 5 GHz `5745 MHz` Ch 149, VHT 40 MHz, AP `00:E6:0E:BC:94:B0`) |
| **Client IPv4 Subnet** | `172.19.0.0/23` (e.g. `172.19.1.189/23`) | `10.0.0.0/23` (e.g. `10.0.0.180/23`, mask `255.255.254.0`, lease `10800 s`) |
| **Cabin Gateway IP & MAC** | `172.19.0.1` | `10.0.0.1` (`52:54:00:4a:e4:b2` — QEMU/KVM virtual NIC) |
| **Cabin Firewall Appliance** | Kong API Gateway (`172.16.128.1`) | FortiGate-VM (`DHCP Option 224` = `46:47:56:4d:53:4c:54:4d:32:35:30:30:34:38:32:30:00` → ASCII `FGVMSLTM25004820`) |
| **Cabin DNS Server IP** | `172.16.128.1` | `10.0.0.1` |
| **DHCP Domain Search (Option 15/119)** | **Sent**: `search wifi.delta.com` | **Omitted!** (Triggers the Linux `systemd-resolved` `NXDOMAIN` trap; see §2.1) |
| **Onboard Portal IP (`wifi.delta.com`)** | `172.16.128.1` (`Kong`) | `192.168.20.12` (`wifi.delta.com`) & `192.168.20.11` (`deltawifi.com`) (`nginx/1.29.4`) |
| **Link MTU** | `1380` bytes (`23/25` of 1500) | `1380` bytes (`23/25` of 1500; 120-byte GRE/IPsec/GTP tunnel overhead) |
| **ICMP Echo (`ping`) to Gateway/Portal** | Answered locally | **100% dropped** on both `10.0.0.1` and `192.168.20.12`! |
| **UDP `:53` DNS RTT to Cabin** | `~1,200 µs` (`1.2 ms`) | `1,627 µs` (`1.6 ms`) |
| **TCP `:443` Portal Handshake RTT** | `~1,100 µs` (`1.1 ms`) | `1,550 µs` (`1.5 ms`) |
| **Satellite Ground RTT (`1.1.1.1`)** | `~550,000–650,000 µs` | `587,000–647,000 µs` (avg `615,000 µs`, 0% loss, GEO satellite hop) |
| **Satellite / Cabin RTT Ratio (`p/q`)** | `~500 / 1` | `615000 / 1550 = 12300 / 31` (`~397×` slower over satellite than cabin server) |

---

## 2. The Five Traps That Break In-Flight Wi-Fi on Linux (and How `qwave` Solves Them)

### Trap 1: Missing DHCP `domain_name` + `systemd-resolved` Global DNS (`NXDOMAIN` on `wifi.delta.com`)
- **Mechanism**: On the FortiGate-VM regional cabin (`10.0.0.0/23`), the client requests `requested_domain_name = 1` and `requested_domain_search = 1`, but the DHCP server (`10.0.0.1`) returns neither.
- When `systemd-resolved` has Global DNS servers configured (e.g., `DNS=1.1.1.1 8.8.8.8` in `/etc/systemd/resolved.conf.d/99-8b-resilient-dns.conf`) and `wlan0` has no routing domain, queries for `wifi.delta.com` are sent to `8.8.8.8` / `1.1.1.1`.
- Because `wifi.delta.com` has **no public `A` record on the internet** (it exists only on the aircraft's internal DNS server `10.0.0.1` → `192.168.20.12` or `172.16.128.1`), public DNS replies **`NXDOMAIN`**, completely breaking portal login and flight telemetry.
- **How `qwave` Solves It (`qwave_core::mesh` + `qwave.rs`)**:
  1. `qwave_core::mesh::build_dns_a_query` sends a 32-byte RFC 1035 UDP DNS `A` query directly to the cabin gateway (`10.0.0.1:53` or `172.16.128.1:53`), resolving `wifi.delta.com` → `192.168.20.12` in `1.6 ms` regardless of OS resolver state.
  2. `probe_delta_inflight_context` passes `--resolve wifi.delta.com:443:192.168.20.12` to `curl` so onboard API probes never fail.
  3. `probe_delta_inflight_context` automatically self-heals the active NetworkManager profile:
     ```bash
     nmcli connection modify "DeltaWiFi.com" ipv4.dns-search "~delta.com,~deltawifi.com,wifi.delta.com"
     nmcli device reapply wlan0
     ```

### Trap 2: 100% ICMP Echo (`ping`) Drop on Cabin Gateways (`10.0.0.1` & `192.168.20.12`)
- **Mechanism**: The onboard FortiGate-VM (`10.0.0.1`) and portal server (`192.168.20.12`) drop 100% of ICMP echo requests (`4 packets transmitted, 0 received, 100% packet loss`), even while answering UDP `:53` in `1,627 µs` and TCP `:443` in `1,550 µs`.
- **How `qwave` Solves It**: `qwave` never uses ICMP `ping` to test cabin gateway health. It measures integer microsecond RTT using a direct UDP `:53` DNS query (`cabin_dns_rtt_us`) and TCP `:443` connect.

### Trap 3: Akamai Satellite `sorry-server` Redirect on `https://www.delta.com`
- **Mechanism**: Over the aircraft's satellite egress IP, requesting `https://www.delta.com/` triggers an Akamai `302` redirect to `http://ssp.delta.com/content/dam/delta-www/sorry-server/delta_sorry.html`.
- **How `qwave` Solves It**: When connected to `DeltaWiFi.com`, typing `delta`, `delta airlines`, `flight`, or `delta.com` in `qwave` or `qwave-qt` routes directly to `https://wifi.delta.com/` (`1.5 ms` onboard server with valid DigiCert TLSv1.3 certificate for `DNS:wifi.delta.com, DNS:deltawifi.com`).

### Trap 4: Link MTU `1380` (`p/q = 23/25` of 1500) & PMTUD Blackholes
- **Mechanism**: Both aircraft configure `wlan0` with `mtu 1380` (`120` bytes of tunnel encapsulation overhead). Because the cabin firewall blocks ICMP, Path MTU Discovery (PMTUD) packets can be dropped if any socket attempts 1500-byte frames.
- **How `qwave` Solves It**: `classify_inflight_link_pq` computes `mtu_efficiency_pq = Rational::new(mtu, 1500)` (`23/25`) and `max_safe_tcp_mss_bytes = mtu - 40` (`1340` bytes).

### Trap 5: Schema Divergence on `https://wifi.delta.com/api/flight-data`
- **Widebody (`DAL120`, Airbus A350 `N510DN`)**:
  - Provides `"flightPhase": "Cruise"` and integer `"timeToGo": 9` (minutes).
- **Regional Jet (`Delta 4965`, CRJ-900 `N292PQ`)**:
  ```json
  {
    "vehicleId": "N292PQ",
    "cached": null,
    "timestamp": "2026-11-03 02:37:10",
    "airspeed": null,
    "airTemperature": -7,
    "altitude": 30419,
    "destination": "KORF",
    "distanceToGo": 2770.25,
    "doorState": "Closed",
    "eta": "09:20.8",
    "flightDuration": null,
    "flightId": "N292PQ-KMSP-KORF-2026-11-03-0156",
    "flightNumber": "4965",
    "groundspeed": 447.875,
    "heading": 124.82666,
    "latitude": 43.994236,
    "longitude": -91.31012,
    "noseId": null,
    "origin": "KMSP",
    "paState": false,
    "timeToGo": null,
    "wheelWeightState": "Off",
    "providerFlightId": "N292PQ-KMSP-KORF-2026-11-03-0156"
  }
  ```
- **Additional Onboard Endpoints Discovered on `https://wifi.delta.com/` (`192.168.20.12`)**:
  - **`GET /api/device-details`**:
    ```json
    {
      "deviceGuid": "YTA6YjM6Mzk6MDg6Zjc6NDZfMTAuMC4wLjE4MA==",
      "deviceLanIp": "10.0.0.180",
      "deviceMac": "null",
      "devicePolicy": "DalPedPremium",
      "href": "",
      "timestamp": "2026-11-03 02:43:13",
      "deviceId": "YTA6YjM6Mzk6MDg6Zjc6NDZfMTAuMC4wLjE4MA==",
      "deviceCategory": "PED"
    }
    ```
    *(Note: `deviceGuid` / `deviceId` is Base64 for `<mac>_<lan_ip>`, e.g., `a0:b3:39:08:f7:46_10.0.0.180`. `devicePolicy` is `"DalPedPremium"` when authenticated for full internet).*
  - **`GET /api/services`**:
    ```json
    {
      "connectivity": true,
      "iptv": true,
      "other": [
        {"serviceName": "IFC", "serviceState": "Available", "href": null},
        {"serviceName": "BTV", "serviceState": "Available", "href": null},
        {"serviceName": "W-IFE", "serviceState": "Disabled", "href": null},
        {"serviceName": "WAN", "serviceState": "Available", "href": null},
        {"serviceName": "Portal", "serviceState": "Available", "href": null}
      ]
    }
    ```
  - **`GET /ota-content/media/toggle.json`**: Polling intervals and timeouts (`flightData: 16000ms`, `deviceDetails: 10000ms`, `service: 10000ms`).
  - **`GET /assets/common-auth-config.json`**: SkyMiles & OAuth endpoints (`https://signin.delta.com`, `https://www.delta.com/cabinWiFiAuth`).
