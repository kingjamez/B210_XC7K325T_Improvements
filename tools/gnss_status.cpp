// gnss_status: read the K7 GNSS/PPS telemetry (fpga/top/b200/gnss_pps_telemetry.v)
// through stock UHD's user settings registers.
//
//   gnss_status [--args ARGS] [--fpga PATH] [--seconds N]
//               [--rx-pin a|b] [--tx on|off] [--baud N|host] [--uhd-uart on|off] [--clear]
//               [--osc-ref gps|ext]   (oscillator monitor reference, telemetry >= 1.6)
//               [--clock internal|external|gpsdo]   (UHD clock source, 3 s settle)
//               [--time-source gpsdo|external|internal|none]
//               [--ubx-probe] [--ubx-config] [--ubx-reset]
//
// --rx-pin/--tx/--baud write the CTRL register before monitoring:
//   --rx-pin a|b   take GPS UART RX from A14 (a) or B14 (b, default)
//   --tx on        drive UART TX on the *other* pin. Only use once the
//                  wiring is confirmed: driving a pin that is a GPS output
//                  causes contention.
//   --baud host    use UHD's 115200; otherwise N baud (default image: 9600)
//   --uhd-uart on  feed the GPS RX pin to UHD's GPSDO UART (CTRL[3], default
//                  off). Leave off unless UHD accepts the module as a GPSDO:
//                  unread UART packets break UHD's control path.
//
// The "baud" columns are measured by the FPGA from the shortest bit on each
// pin (readback 8), so they show the module's real rate whatever CTRL says.
//
// --ubx-probe  Test whether the FPGA can talk TO the u-blox (is module RXD
//              wired?). Checks the TX pin is quiet first, enables the host
//              UART bridge on it, sends UBX-MON-VER and looks for the reply on
//              the RX pin. Restores CTRL afterwards. Only run this once V_IO
//              (u-blox pin 7) is confirmed 3.3 V.
//
// --ubx-config Same safety checks, then send UBX-CFG-VALSET (RAM) for GP talker
//              + NMEA 2.1 so stock UHD accepts the module as a GPSDO. Prints
//              the ACK/NAK and the NMEA that follows. Lost at power-off.
// --ubx-reset  Same safety checks, then UBX-CFG-RST cold hardware reset: the
//              module returns to its power-up defaults (like a replug).
//
// Receive-only otherwise; nothing is transmitted over RF.

#include <uhd/types/wb_iface.hpp>
#include <uhd/usrp/multi_usrp.hpp>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

static constexpr double BUS_CLK = 100e6;

// Snap a measured bit time to the nearest standard UART rate (within 5%).
static std::string baud_str(uint32_t min_run, double mcr)
{
    if (min_run == 0xffffffffu || min_run == 0) return "-";
    const double raw = mcr / min_run;
    for (double b : {4800., 9600., 19200., 38400., 57600., 115200., 230400., 460800., 921600.})
        if (std::abs(raw / b - 1.0) < 0.05) return std::to_string(int(b));
    return "~" + std::to_string(int(raw + 0.5)) + "?";
}

// UBX frame with Fletcher checksum over class..payload
static std::vector<uint8_t> ubx_frame(uint8_t cls, uint8_t id, const std::vector<uint8_t>& pl)
{
    std::vector<uint8_t> f = {0xB5, 0x62, cls, id, uint8_t(pl.size()), uint8_t(pl.size() >> 8)};
    f.insert(f.end(), pl.begin(), pl.end());
    uint8_t a = 0, b = 0;
    for (size_t i = 2; i < f.size(); i++) { a += f[i]; b += a; }
    f.push_back(a);
    f.push_back(b);
    return f;
}

// Send one UBX frame through the host UART bridge and collect what comes back.
// Safety first: the TX pin must show zero toggles (not driven by the module).
// Restores CTRL (TX off, bridge off) before returning. 0 = ok.
template <typename RB, typename WR>
static int ubx_exchange(RB rb, WR wr, const std::vector<uint8_t>& frame, int collect_ms,
    std::vector<uint8_t>& got, const char** tx_pin_name)
{
    const uint32_t ctrl0  = uint32_t(rb(6));
    const bool rx_on_a    = ctrl0 & 1;
    const char* rx_name   = rx_on_a ? "A14" : "B14";
    const char* tx_name   = rx_on_a ? "B14" : "A14";
    *tx_pin_name = tx_name;

    // 1. Safety: the pin we would drive must be quiet (not a module output).
    wr(1, 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    const uint64_t tog = rb(5);
    const uint32_t tx_tog = rx_on_a ? uint32_t(tog) : uint32_t(tog >> 32);
    const uint32_t rx_tog = rx_on_a ? uint32_t(tog >> 32) : uint32_t(tog);
    std::printf("toggles in 1.5 s: RX %s = %u, TX candidate %s = %u\n", rx_name, rx_tog, tx_name, tx_tog);
    if (rx_tog < 100) {
        std::printf("RX pin shows no UART activity; pick the right --rx-pin first.\n");
        return 1;
    }
    if (tx_tog != 0) {
        std::printf("REFUSING: %s is toggling, so it is driven by something. Not driving it.\n", tx_name);
        return 1;
    }
    const uint32_t div = ctrl0 >> 16;
    std::printf("baud: %s\n", div ? std::to_string(int(BUS_CLK / div + 0.5)).c_str() : "host 115200");

    // 2. Enable bridge TX on the quiet pin, send the frame.
    wr(0, ctrl0 | 0x6);
    wr(1, 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    for (uint8_t byte : frame) wr(2, byte);

    // 3. Collect RX bytes, reading the 256-byte ring as it fills.
    uint32_t have = 0;
    bool overflow = false;
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(collect_ms);
    while (std::chrono::steady_clock::now() < end) {
        const uint32_t total = uint32_t(rb(9));
        if (total - have > 256) { overflow = true; have = total - 256; }
        while (have < total) {
            const uint64_t w = rb(16 + ((have & 0xff) >> 3));
            for (uint32_t k = have & 7; k < 8 && have < total; k++, have++)
                got.push_back(uint8_t(w >> (8 * k)));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    wr(0, ctrl0);   // restore: TX off, bridge off
    std::printf("collected %zu bytes%s; TX disabled again\n", got.size(),
        overflow ? " (ring overflowed; some bytes skipped)" : "");
    return 0;
}

// Index of the first UBX frame of class/id in buf, or -1.
static long find_ubx(const std::vector<uint8_t>& buf, uint8_t cls, uint8_t id, size_t from = 0)
{
    for (size_t i = from; i + 6 <= buf.size(); i++)
        if (buf[i] == 0xB5 && buf[i + 1] == 0x62 && buf[i + 2] == cls && buf[i + 3] == id) return long(i);
    return -1;
}

template <typename RB, typename WR>
static int run_ubx_probe(RB rb, WR wr)
{
    std::vector<uint8_t> got;
    const char* tx_name;
    if (int rc = ubx_exchange(rb, wr, ubx_frame(0x0A, 0x04, {}), 1500, got, &tx_name)) return rc;

    // Look for a MON-VER reply: B5 62 0A 04 len_lo len_hi payload...
    const long at = find_ubx(got, 0x0A, 0x04);
    if (at >= 0) {
        const size_t i = size_t(at);
        const size_t len = got[i + 4] | (got[i + 5] << 8);
        std::printf("\nUBX-MON-VER reply found (payload %zu bytes): module RXD IS wired to %s.\n", len, tx_name);
        auto field = [&](size_t off, size_t n) {
            std::string s;
            for (size_t k = 0; k < n && i + 6 + off + k < got.size(); k++) {
                const char c = char(got[i + 6 + off + k]);
                if (!c) break;
                s += c;
            }
            return s;
        };
        std::printf("  swVersion: %s\n  hwVersion: %s\n", field(0, 30).c_str(), field(30, 10).c_str());
        for (size_t off = 40; off + 30 <= len; off += 30)
            std::printf("  ext: %s\n", field(off, 30).c_str());
        return 0;
    }
    std::printf("\nNo UBX-MON-VER reply. Either module RXD is not wired to %s, or the baud is wrong.\n"
                "If the NMEA stream above looked healthy at this baud, treat RXD as not connected.\n", tx_name);
    return 3;
}

// UBX-CFG-VALSET (RAM layer) that makes the MAX-M10S output what stock UHD's
// gps_ctrl accepts and can keep up with. Key IDs from the u-blox M10 SPG 5.10
// interface description (UBX-21035062 R02, protocol 34.10):
//   CFG-NMEA-MAINTALKERID        0x20930031 E1  1 = GP  ($GPGGA/$GPRMC)
//   CFG-NMEA-PROTVER             0x20930001 E1 21 = NMEA 2.1 (RMC ends ",*hh")
//   CFG-MSGOUT-NMEA_ID_GSV_UART1 0x209100c5 U1  0   GSV, GSA, VTG and GLL off: keep only
//   CFG-MSGOUT-NMEA_ID_GSA_UART1 0x209100c0 U1  0   GGA + RMC, since every byte
//   CFG-MSGOUT-NMEA_ID_VTG_UART1 0x209100b1 U1  0   becomes a UHD control packet
//   CFG-MSGOUT-NMEA_ID_GLL_UART1 0x209100ca U1  0
//   CFG-RATE-MEAS                0x30210001 U2 500 ms: 2 Hz, so UHD's 650 ms
//                                              detection window always holds a burst
// The module has no flash and no backup supply: resend after every power-up.
static std::vector<uint8_t> uhd_nmea_valset()
{
    std::vector<uint8_t> pl = {0x00, 0x01, 0x00, 0x00};   // version 0, layers = RAM
    auto key = [&](uint32_t k, uint32_t v, int bytes) {
        for (int i = 0; i < 4; i++) pl.push_back(uint8_t(k >> (8 * i)));
        for (int i = 0; i < bytes; i++) pl.push_back(uint8_t(v >> (8 * i)));
    };
    key(0x20930031, 1, 1);
    key(0x20930001, 21, 1);
    key(0x209100c5, 0, 1);
    key(0x209100c0, 0, 1);
    key(0x209100b1, 0, 1);
    key(0x209100ca, 0, 1);
    key(0x30210001, 500, 2);
    return ubx_frame(0x06, 0x8A, pl);
}

// Print complete NMEA sentences found in buf.
static void print_nmea(const std::vector<uint8_t>& buf)
{
    std::string line;
    for (uint8_t c : buf) {
        if (c == '$') line = "$";
        else if (!line.empty()) {
            if (c == '\r' || c == '\n') { std::printf("  %s\n", line.c_str()); line.clear(); }
            else if (c >= 0x20 && c < 0x7f) line += char(c);
            else line.clear();
        }
    }
}

// UBX-CFG-RST: navBbrMask 0xFFFF (cold start), resetMode 0x00 (hardware
// reset now). Equivalent to a power cycle for this module (no backup supply):
// RAM config is lost, defaults return. Not acknowledged by the receiver.
template <typename RB, typename WR>
static int run_ubx_reset(RB rb, WR wr)
{
    std::vector<uint8_t> got;
    const char* tx_name;
    const auto frame = ubx_frame(0x06, 0x04, {0xFF, 0xFF, 0x00, 0x00});
    std::printf("UBX-CFG-RST (cold, hardware):");
    for (uint8_t b : frame) std::printf(" %02X", b);
    std::printf("\n");
    if (int rc = ubx_exchange(rb, wr, frame, 4000, got, &tx_name)) return rc;
    std::printf("NMEA in the 4 s after the reset:\n");
    print_nmea(got);
    return 0;
}

template <typename RB, typename WR>
static int run_ubx_config(RB rb, WR wr)
{
    std::vector<uint8_t> got;
    const char* tx_name;
    const auto frame = uhd_nmea_valset();
    std::printf("UBX-CFG-VALSET:");
    for (uint8_t b : frame) std::printf(" %02X", b);
    std::printf("\n");
    if (int rc = ubx_exchange(rb, wr, frame, 2500, got, &tx_name)) return rc;

    // UBX-ACK-ACK (05 01) / ACK-NAK (05 00), payload = acked class/id
    int result = 4;
    for (size_t i = 0; i + 8 <= got.size(); i++) {
        if (got[i] == 0xB5 && got[i + 1] == 0x62 && got[i + 2] == 0x05 && got[i + 6] == 0x06 && got[i + 7] == 0x8A) {
            if (got[i + 3] == 0x01) { std::printf("\nUBX-ACK-ACK for CFG-VALSET: config applied.\n"); result = 0; }
            if (got[i + 3] == 0x00) { std::printf("\nUBX-ACK-NAK for CFG-VALSET: config REJECTED.\n"); result = 5; }
            break;
        }
    }
    if (result == 4) std::printf("\nNo ACK/NAK for CFG-VALSET seen.\n");

    // Show complete NMEA sentences received after the command.
    std::printf("NMEA after the command:\n");
    print_nmea(got);
    return result;
}

int main(int argc, char** argv)
{
    std::string args = "type=b200", fpga, rx_pin, tx, baud, tsrc, uhd_uart, osc_ref, clk;
    int seconds      = 10;
    bool clear       = false;
    bool ubx_probe   = false;
    bool ubx_config  = false;
    bool ubx_reset   = false;
    for (int i = 1; i < argc; i++) {
        auto next = [&](void) { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
        if (!std::strcmp(argv[i], "--args")) args = next();
        else if (!std::strcmp(argv[i], "--fpga")) fpga = next();
        else if (!std::strcmp(argv[i], "--seconds")) seconds = std::stoi(next());
        else if (!std::strcmp(argv[i], "--rx-pin")) rx_pin = next();
        else if (!std::strcmp(argv[i], "--tx")) tx = next();
        else if (!std::strcmp(argv[i], "--uhd-uart")) uhd_uart = next();
        else if (!std::strcmp(argv[i], "--osc-ref")) osc_ref = next();
        else if (!std::strcmp(argv[i], "--clock")) clk = next();
        else if (!std::strcmp(argv[i], "--baud")) baud = next();
        else if (!std::strcmp(argv[i], "--time-source")) tsrc = next();
        else if (!std::strcmp(argv[i], "--clear")) clear = true;
        else if (!std::strcmp(argv[i], "--ubx-probe")) ubx_probe = true;
        else if (!std::strcmp(argv[i], "--ubx-config")) ubx_config = true;
        else if (!std::strcmp(argv[i], "--ubx-reset")) ubx_reset = true;
        else { std::fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (!fpga.empty()) args += ",fpga=" + fpga;
    args += ",enable_user_regs";

    auto usrp = uhd::usrp::multi_usrp::make(args);
    auto regs = usrp->get_user_settings_iface(0);
    if (!regs) {
        std::fprintf(stderr, "no user settings interface (UHD too old?)\n");
        return 1;
    }
    // UHD's user settings iface takes byte offsets: readback N at N*8, write N at N*4.
    auto rb = [&](uint32_t a) { return regs->peek64(a * 8); };
    auto wr = [&](uint32_t a, uint32_t v) { regs->poke32(a * 4, v); };

    uint64_t id = rb(0);
    if ((id >> 32) != 0x4B374F50) {
        std::fprintf(stderr,
            "telemetry not found (readback 0 = 0x%016llx). Is this a K7 Open image?\n",
            (unsigned long long)id);
        return 1;
    }
    std::printf("K7 GNSS telemetry v%u.%u\n", unsigned((id >> 16) & 0xffff), unsigned(id & 0xffff));

    uint32_t ctrl = uint32_t(rb(6));
    if (!rx_pin.empty()) ctrl = (ctrl & ~1u) | (rx_pin == "a" ? 1u : 0u);
    if (!tx.empty()) ctrl = (ctrl & ~2u) | (tx == "on" ? 2u : 0u);
    if (!uhd_uart.empty()) ctrl = (ctrl & ~8u) | (uhd_uart == "on" ? 8u : 0u);
    if (!osc_ref.empty()) ctrl = (ctrl & ~16u) | (osc_ref == "ext" ? 16u : 0u);
    if (!baud.empty()) {
        uint32_t div = baud == "host" ? 0 : uint32_t(BUS_CLK / std::stod(baud) + 0.5);
        ctrl = (ctrl & 0xffffu) | (div << 16);
    }
    if (ctrl != uint32_t(rb(6))) wr(0, ctrl);
    if (clear) wr(1, 1);
    ctrl = uint32_t(rb(6));
    std::printf("CTRL 0x%08x: rx=%s tx=%s baud=%s uhd_uart=%s\n", ctrl, (ctrl & 1) ? "A14" : "B14",
        (ctrl & 2) ? "ON" : "off",
        (ctrl >> 16) ? std::to_string(int(BUS_CLK / (ctrl >> 16) + 0.5)).c_str() : "host(115200)",
        (ctrl & 8) ? "on" : "off");
    if (((id >> 16) & 0xffff) > 1 || (id & 0xffff) >= 4) {
        const uint32_t ac = uint32_t(rb(10));
        std::printf("gps_autoconfig: %s\n", (ac & 4) ? "ACK (module configured, UHD UART open)" :
            (ac & 8) ? "NAK (module rejected config)" : (ac & 1) ? "skipped (pin check failed)" :
            (ac & 2) ? "sent, no reply" : "pending");
    }

    if (ubx_probe) return run_ubx_probe(rb, wr);
    if (ubx_config) return run_ubx_config(rb, wr);
    if (ubx_reset) return run_ubx_reset(rb, wr);

    if (!tsrc.empty()) usrp->set_time_source(tsrc, 0);
    if (!clk.empty()) {
        usrp->set_clock_source(clk, 0);
        std::this_thread::sleep_for(std::chrono::seconds(3));   // reference PLL settles
    }
    std::printf("time source: %s   clock source: %s\n",
        usrp->get_time_source(0).c_str(), usrp->get_clock_source(0).c_str());
    for (auto& s : usrp->get_mboard_sensor_names(0)) {
        // Raw NMEA carries the position: keep it out of logs and pasted output.
        if (s == "gps_gpgga" || s == "gps_gprmc") continue;
        try {
            std::printf("  sensor %-12s %s\n", s.c_str(),
                usrp->get_mboard_sensor(s, 0).to_pp_string().c_str());
        } catch (const std::exception& e) {
            std::printf("  sensor %-12s ERROR %s\n", s.c_str(), e.what());
        }
    }

    const double mcr = usrp->get_master_clock_rate();
    std::printf("master clock %.6f MHz (tick = %.3f ns)\n\n", mcr / 1e6, 1e9 / mcr);
    const bool health = (id & 0xffff) >= 5 || ((id >> 16) & 0xffff) > 1;   // telemetry >= 1.5
    std::printf("%3s | %-34s | %-34s | %-21s | %-15s | %s%s\n", "s",
        "GPS PPS (B15) edges/period/width/age", "EXT PPS edges/period/width/age",
        "A14 / B14 toggles", "A14 / B14 baud", "levels",
        health ? " | PPS health gps/ext (valid missed bad)" : "");

    const bool osc = (id & 0xffff) >= 6 || ((id >> 16) & 0xffff) > 1;   // telemetry >= 1.6
    const uint64_t osc0 = osc ? rb(12) : 0;
    for (int n = 0; n < seconds; n++) {
        uint64_t e = rb(1), p = rb(2), a = rb(3), w = rb(4), t = rb(5), l = rb(7), m = rb(8);
        auto fmt = [&](int sh, char* buf) {
            uint32_t ed = uint32_t(e >> sh), pe = uint32_t(p >> sh), wi = uint32_t(w >> sh),
                     ag = uint32_t(a >> sh);
            if (!ed) std::snprintf(buf, 64, "none");
            else
                std::snprintf(buf, 64, "%5u %+9.3fppm %6.1fms %5.0fms", ed,
                    pe ? (pe / mcr - 1.0) * 1e6 : 0.0, wi / mcr * 1e3,
                    ag == 0xffffffffu ? -1.0 : ag / mcr * 1e3);
        };
        char g[64], x[64];
        fmt(32, g);
        fmt(0, x);
        std::printf("%3d | %-34s | %-34s | %10u %10u | %7s %7s | A=%d B=%d gps=%d ext=%d\n", n,
            g, x, uint32_t(t >> 32), uint32_t(t), baud_str(uint32_t(m >> 32), mcr).c_str(),
            baud_str(uint32_t(m), mcr).c_str(), int(l & 1), int((l >> 1) & 1),
            int((l >> 2) & 1), int((l >> 3) & 1));
        if (health) {
            const uint64_t h = rb(11);
            std::printf("    | gps %s missed %u bad %u | ext %s missed %u bad %u",
                (l >> 4) & 1 ? "VALID  " : "invalid", unsigned(h >> 48), unsigned((h >> 32) & 0xffff),
                (l >> 5) & 1 ? "VALID  " : "invalid", unsigned((h >> 16) & 0xffff), unsigned(h & 0xffff));
            // Both ages come from one 64-bit readback, so they are sampled together:
            // ext edge time - gps edge time = age_gps - age_ext ticks.
            const uint32_t ag = uint32_t(a >> 32), ae = uint32_t(a);
            if (((l >> 4) & 1) && ((l >> 5) & 1) && ag != 0xffffffffu && ae != 0xffffffffu) {
                double d = (double(ag) - double(ae)) / mcr;
                if (d > 0.5) d -= 1.0;
                if (d < -0.5) d += 1.0;
                std::printf(" | EXT - GPS edge %+.1f ns", d * 1e9);
            }
            std::printf("\n");
        }
        if (osc) {
            // bus_clk = VCTCXO x 2.5 = 100 MHz nominal; wrap-safe differences
            const uint64_t s = rb(12), last = rb(13) & 0xffffffffu;
            const uint32_t de = uint32_t(((s >> 48) - (osc0 >> 48)) & 0xffff);
            const uint64_t ds = (s - osc0) & 0xFFFFFFFFFFFFull;
            std::printf("    | VCTCXO vs %s PPS: last 1 s %+8.4f ppm", (ctrl & 16) ? "SMA" : "GPS",
                last ? (double(last) / 1e8 - 1.0) * 1e6 : 0.0);
            if (de) std::printf(" | mean over %u s %+9.5f ppm", de, (double(ds) / (double(de) * 1e8) - 1.0) * 1e6);
            std::printf("\n");
        }
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    return 0;
}
