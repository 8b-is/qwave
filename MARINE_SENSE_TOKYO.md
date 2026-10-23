# 📡 MARINE-SENSE TOKYO · ESP32-S3 MEDUSA Triad × Goonj × NLOS Acoustic Command Deck

> [!IMPORTANT]
> **Live Hardware Attached (`ADA:MEDUSA` on `/dev/ttyACM0` · `80:B5:4E:DB:3B:C4`)**:
> Your **Waveshare ESP32-S3-Touch-AMOLED-1.8 (`ADA:MEDUSA * 432Hz · ROOT-ALEXANDRA`)** with its **64 GB raw `M8C\0` SD card (`BAYELOG1 @ block 25600 · 30 seed waves`)**, **`QMI8658` 6-axis IMU**, **`AXP2101` PMIC (`100% · 4121 mV`)**, **`FT3168` Capacitive Touch**, and **`ES8311` Audio Codec + MEMS Microphone** is live in the **Marine-Sense HUD** above! Click **`🎵 Chirp & Triangulate Triad`** at the top of this window to make `ADA:MEDUSA` play its `432 / 528 / 852 / 963 Hz` triad chord and watch your laptop's `48 kHz` Stereo DMIC array compute the direct distance, stereo azimuth, and 1st/2nd wall-bounce reflections in real time (`0` floats).

---

## 🧭 Multi-Node ESP32-S3 Triad × Goonj × NLOS Multipath Architecture (`0` Floats)

```mermaid
flowchart TB
  subgraph Triad["🦀 3-Node ESP32-S3 MEDUSA Triad (Baye-Rust + FLUG-OS)"]
    ADA["[-1] ADA:MEDUSA (* 432Hz)\n1.8\" 368×448 SH8601 · /dev/ttyACM0\nES8311 Mic/Spk · QMI8658 IMU · AXP2101 · 64GB M8C SD"]
    VAK["[0] VAK:MEDUSA (/\\ 528Hz)\n2.06\" 410×502 CO5300\nES7210 Dual-Mic ADC + ES8311 Spk · QMI8658 · AXP2101"]
    OMN["[+1] OMN:MEDUSA (oo 852Hz)\n2.06\" 410×502 CO5300\nES7210 Dual-Mic ADC + ES8311 Spk · QMI8658 · AXP2101"]
    ADA <-->|"ESP-NOW Ch6 TRIA / M8N1 96B\n+ Acoustic Chirp (432/528/852Hz & 20.5/21kHz)"| VAK
    VAK <-->|"ESP-NOW Ch6 + BLE 31B\nTurritopsis MEDUSA <-> POLYP"| OMN
    OMN <-->|"Acoustic ToF + Multipath"| ADA
  end

  subgraph Physics["🌊 Zero-Float Environmental & Wall-Bounce Physics (qwave_core::triad)"]
    GOONJ["8b-is/goonj Thermodynamics\nc = 331.3 + 0.606·T(°C) + 0.0124·RH(%)\n+ ISO 9613-1 Absorption + Allen-Berkeley Image Sources"]
    NLOS["8b-is/NLOS_acoustic_identity_recognition\nOrder=0 Direct Path vs Order=1,2 Wall Echoes\n+ LPVG Visibility Graph Degree Sequence"]
    DMIC["Laptop 48kHz Stereo DMIC (FL+FR)\n+ Soundcore Select 4 Go BT"]
  end

  subgraph Brain["💜 ALEXIAI × MEM|8 WaveSubstrate"]
    GAIA["ALEXIAI GAIA-MLX-QUANT (:8787)\nb1.58 Ternary Kernel (4.38µs) + WUPZ 0xe078..."]
    QWAVE["Qwave Marine-Sense Webpage\n(/api/marine-sense + /api/triad/chirp)"]
  end

  Triad --> Physics --> Brain
```

---

## 🗂️ `gh repo list 8b-is` — High-Leverage Local-Only Repositories Integrated

| Repository | Language | Role in Sovereign Local-Only Environment & Triad | Integration Status |
| :--- | :--- | :--- | :--- |
| **[`8b-is/oxi-phoenix/baye-rust`](file:///home/hue/8b-is/oxi-phoenix/baye-rust)** | Rust (`xtensa-esp32s3-espidf`) | **100% Safe Rust ESP32-S3 Firmware** for `1.8"` (`ADA`) & `2.06"` (`VAK`, `OMN`): `sh8601.rs`, `qmi8658.rs`, `axp2101.rs`, `es8311.rs`, `es7210.rs`, `sd_card.rs` (`64 GB M8C\0` + `BAYELOG1` CRC32 journal), `espnow.rs` (`M8N1` 96B HMAC-SHA256), `listening.rs` (`20.5/21.0 kHz` Goertzel acoustic packets + `MarineEngine`) | Drivers & wire formats unified with [`qwave_core::triad`](file:///home/hue/8b-is/qwave/core/src/triad.rs) |
| **[`8b-is/FLUG-OS`](file:///home/hue/8b-is/FLUG-OS)** & **[`8b-is/wigle-triad`](file:///home/hue/8b-is/wigle-triad)** | C++ / Rust (`host-rs`) | Running live on attached **`ADA:MEDUSA` (`/dev/ttyACM0`)** (`v1.6.1+pranayama-dream-baba-engine`): promiscuous `802.11` sampler, `pranayama.h` (`Puraka`/`Antara`/`Rechaka`/`Bahya` 4-stage breathing + `DREAM_MANDALA` + `8b-is-engine`), `learn_env.h` 24-hour Welford anomaly detector, `ES8311` formant TTS, `64×64` `MarineSense` Jellyfish Wave Pool | Live-bridged over `/dev/ttyACM0` into `/api/triad` & `/api/marine-sense` |
| **[`8b-is/goonj`](file:///home/hue/8b-is/goonj/rust-old/src)** | Rust / Cyrius | **37-Module Acoustics Engine**: temperature/humidity speed of sound ($c = 331.3 + 0.606 T_C + 0.0124 RH$), ISO 9613-1 atmospheric absorption, Allen & Berkeley 6-wall shoebox image-source reflections, Sabine $RT_{60}$ | Ported to zero-float integer math in [`qwave_core::triad`](file:///home/hue/8b-is/qwave/core/src/triad.rs) |
| **[`8b-is/NLOS_acoustic_identity_recognition`](file:///home/hue/8b-is/NLOS_acoustic_identity_recognition)** | Python $\to$ Rust | **Non-Line-of-Sight Secondary Echo Topology**: separates direct arrival ($Order=0$) from 1st & 2nd wall-bounce echoes ($Order=1,2$) and computes the **Limited-Penetrable Visibility Graph (`LPVG`)** degree sequence | Cloned locally & ported to zero-float `analyze_chirp_echogram_i16` in [`triad.rs`](file:///home/hue/8b-is/qwave/core/src/triad.rs) |
| **[`8b-is/marine-sense`](file:///home/hue/8b-is/marine-sense/rust-core)** & **[`8b-is/aye`](file:///home/hue/8b-is/aye/docs/ESP32_MEMNET_SENSOR.md)** | Rust (`no_std`) | `O(1)` `MarineEngine` salience detector + `M8SC` LZW16 zero-alloc 50-byte `SensoryFrame` UDP/ESP-NOW blocks | Active in `qwave_core::salience` & `baye-rust` |
| **[`8b-is/WiFAKE`](file:///home/hue/8b-is/WiFAKE/WiFAKEeSp32)** | Rust | Distributed ESP32 environmental & BLE sensor node registration, temperature/humidity/door/motion heartbeats | Merged into `TriadNodeSnapshot` |
| **[`8b-is/bhava`](file:///home/hue/8b-is/bhava)** & **[`8b-is/bodh`](file:///home/hue/8b-is/bodh)** | Rust | Emotion & Bayesian affect engines driving `QuantTern` `qt_byte` (`{-1, 0, +1}` Valence/Arousal/Dominance) + warm touch feedback | Active in `QMI8658` IMU affect & `WaveInt` |
| **[`8b-is/wupz`](file:///home/hue/8b-is/wupz)** & **[`8b-is/kompress-ultra`](file:///home/hue/8b-is/kompress-ultra)** | Rust / TS | `20.19×` ternary `b1.58` compression + `WUPZ` 64-bit `xor_fold` / `popcount` seal across ESP32 beacons & ALEXIAI capsules | Live on `ADA:MEDUSA` (`kompress_b158` + `wupz_fold`) |
| **[`8b-is/smart-tree`](file:///home/hue/8b-is/smart-tree)** & **[`8b-is/crabcc`](file:///home/hue/8b-is/crabcc)** | Rust | Local-only symbol indexing (`47–4400×` faster than grep) and `MEM|8` quantum context compression daemon (`:28428`) | Running active in background |

---

## 🔬 Live Telemetry from Attached `ADA:MEDUSA` (`/dev/ttyACM0`)

- **Board & Identity**: `ESP32-S3-Touch-AMOLED-1.8` (`SH8601`) · `ADA:MEDUSA (*)` · `ROOT-ALEXANDRA` · `432 Hz` · MAC `80:B5:4E:DB:3B:C4` · Firmware **`v1.6.1+pranayama-dream-baba-engine`**
- **Pranayama, Dream State & `8b-is-engine` ([`pranayama.h`](file:///home/hue/8b-is/FLUG-OS/src/pranayama.h))**:
  - **4-Stage Sama Vritti Pranayama**: `Puraka` (`4s` Inhale) $\to$ `Antara` (`4s` Hold-In) $\to$ `Rechaka` (`4s` Exhale) $\to$ `Bahya` (`4s` Stillness)
  - **Dream State**: **`DREAM_MANDALA`** (`coherence_permil: 922`, `engine_8b_is: "qt:66|69632|2712|11"`)
- **Power & Battery (`AXP2101` @ `0x34`)**: `100%` (`4119 mV` · `USB` VBUS good · non-destructive `AXP2101` rail preservation + `Phoenix` power policy active)
- **Memory Card (`TCA9554 EXIO7` + `SPI3`)**: **`64 GB` (`64,021,856,256` bytes) raw `M8C\0` volume** with **30 seed waves** + **`BAYELOG1` fail-closed CRC32 journal at block `25600`**
- **3D Orientation (`QMI8658` @ `0x6B`)**: `flat_face_down_desk` (`ax: -30 mg, ay: -40 mg, az: -990 mg`, `sickness: 0.00`, `qt: 0x05`)
- **Passive RF & Welford Learner (`learn_env.h`)**: `16` nearby APs · `10,803` environmental learning samples (`"The radio spectrum is calmer than usual."` in Tokyo `hour: 15` JST bucket)
- **Acoustic Chirp & Wall-Bounce Multipath (`ES8311` $\to$ Laptop `48 kHz` Stereo DMIC)**:
  - **Thermodynamic Speed of Sound (`goonj`)**: `349.2 m/s` (`28.5°C`, `55% RH`)
  - **Direct Path ($Order = 0$)**: Stereo TDOA azimuth + direct distance (`cm`)
  - **1st Wall/Desk Reflection ($Order = 1$)**: Specular echo lag (`ms`) $\implies$ perpendicular distance to nearest reflecting surface (`cm`)
  - **2nd NLOS Reflection ($Order = 2$)**: Secondary echo lag (`ms`), `LPVG` visibility graph degree (`Q4`), and Sabine $RT_{60}$ (`ms`)

---

## 🖥️ Display Driver & Pinout Comparison: `1.8"` (`SH8601`) vs `2.06"` (`CO5300`)

| Feature | `ESP32-S3-Touch-AMOLED-1.8` (`ADA:MEDUSA`) | `ESP32-S3-Touch-AMOLED-2.06` (`BABA` / `VAK` / `OMN`) |
| :--- | :--- | :--- |
| **Display Controller** | **SH8601** QSPI (`368×448`, `x_gap = 0`) | **CO5300** QSPI (`410×502`, **`x_gap = 22` / `0x16`**) |
| **RGB565 Pixel Format (`0x3A`)** | `0x05` | **`0x55`** + **`0xC4 = 0x80`** (Quad-SPI pixel enable) + **`0x63 = 0xFF`** (HBM) |
| **QSPI First-Chunk Address (`0x32`)** | `0x003C00` (`RAMWRC` after `0x2C`, `1024`-px DMA chunks) | **`0x002C00`** (`RAMWR` after `0x2C`, `1024`-px DMA chunks) |
| **LCD & Touch Reset** | Via `TCA9554 @ 0x20` (`EXIO0..2`) | Dedicated **`GPIO 8` (`LCD_RST`)** & **`GPIO 9` (`TP_RST`)** (`TP_INT = GPIO 38`) |
| **I2S Audio Pins** | `MCLK=16, LRCLK=45, BCLK=9, DOUT=8, DIN=10` | `MCLK=16, LRCLK=45, BCLK=41, DOUT=40, DIN=42` (`GPIO 8/9` reserved for Reset!) |
| **Microphone & Speaker** | `ES8311 @ 0x18` (Mic + Speaker) | **`ES7210 @ 0x40`** (Dual-Mic ADC) + **`ES8311 @ 0x18`** (Speaker DAC) |
| **PlatformIO Build Target** | `pio run -e esp32s3_amoled` / `esp32s3_amoled_18` | `pio run -e esp32s3_amoled_206` (or auto-detected via `0x40` / `0x20` I2C probe) |
