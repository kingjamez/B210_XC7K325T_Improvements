// SPDX-License-Identifier: GPL-3.0-or-later
//
// adc_status: ADC overload monitor (fpga/top/b200/adc_monitor.v) through stock
// UHD's user settings registers. Receive only: streams RX (samples discarded)
// so the AD9361 delivers samples, and reads peaks / over-threshold counts.
//
//   adc_status [--args ARGS] [--fpga PATH] [--seconds N] [--freq HZ]
//              [--rate SPS] [--gain DB] [--channels 0|0,1] [--thresh N] [--ant RX2|TX/RX]
//
// peak dBFS = 20 log10(peak / 2048). "over" counts samples with |I| or |Q| >=
// THRESH (default 2047 = full scale), i.e. clipping.

#include <uhd/types/wb_iface.hpp>
#include <uhd/usrp/multi_usrp.hpp>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char** argv)
{
    std::string args = "type=b200", fpga, chans = "0", ant;
    int seconds = 10, thresh = -1;
    double freq = 100e6, rate = 10e6, gain = 40;
    for (int i = 1; i < argc; i++) {
        auto next = [&](void) { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
        if (!std::strcmp(argv[i], "--args")) args = next();
        else if (!std::strcmp(argv[i], "--fpga")) fpga = next();
        else if (!std::strcmp(argv[i], "--seconds")) seconds = std::stoi(next());
        else if (!std::strcmp(argv[i], "--freq")) freq = std::stod(next());
        else if (!std::strcmp(argv[i], "--rate")) rate = std::stod(next());
        else if (!std::strcmp(argv[i], "--gain")) gain = std::stod(next());
        else if (!std::strcmp(argv[i], "--channels")) chans = next();
        else if (!std::strcmp(argv[i], "--thresh")) thresh = std::stoi(next());
        else if (!std::strcmp(argv[i], "--ant")) ant = next();
        else { std::fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (!fpga.empty()) args += ",fpga=" + fpga;
    args += ",enable_user_regs";

    auto usrp = uhd::usrp::multi_usrp::make(args);
    auto regs = usrp->get_user_settings_iface(0);
    if (!regs) { std::fprintf(stderr, "no user settings interface\n"); return 1; }
    auto rb = [&](uint32_t a) { return regs->peek64(a * 8); };
    auto wr = [&](uint32_t a, uint32_t v) { regs->poke32(a * 4, v); };

    const uint64_t id = rb(64);
    if ((id >> 32) != 0x4144434D) {
        std::fprintf(stderr, "ADC monitor not found (readback 64 = 0x%016llx). Image too old?\n",
            (unsigned long long)id);
        return 1;
    }
    std::printf("K7 ADC monitor v%u.%u\n", unsigned((id >> 16) & 0xffff), unsigned(id & 0xffff));

    std::vector<size_t> ch = {0};
    if (chans == "0,1") ch = {0, 1};
    else if (chans == "1") ch = {1};
    usrp->set_rx_rate(rate);
    for (size_t c : ch) {
        usrp->set_rx_freq(uhd::tune_request_t(freq), c);
        usrp->set_rx_gain(gain, c);
        if (!ant.empty()) usrp->set_rx_antenna(ant, c);
    }
    std::printf("rx rate %.3f MS/s, freq %.3f MHz, gain %.1f dB, antenna %s, channels %s\n",
        usrp->get_rx_rate() / 1e6, usrp->get_rx_freq(ch[0]) / 1e6, usrp->get_rx_gain(ch[0]),
        usrp->get_rx_antenna(ch[0]).c_str(), chans.c_str());

    if (thresh >= 0) wr(65, uint32_t(thresh));

    // Keep an RX stream running so the ADC delivers samples; discard them.
    uhd::stream_args_t sargs("sc16", "sc16");
    sargs.channels = ch;
    auto rx = usrp->get_rx_stream(sargs);
    std::atomic<bool> run{true};
    std::thread t([&] {
        std::vector<std::vector<std::complex<int16_t>>> bufs(ch.size(),
            std::vector<std::complex<int16_t>>(rx->get_max_num_samps()));
        std::vector<void*> ptrs;
        for (auto& b : bufs) ptrs.push_back(b.data());
        uhd::rx_metadata_t md;
        uhd::stream_cmd_t cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
        // Multi-channel streamers need a timed start to stay aligned
        cmd.stream_now = ch.size() == 1;
        if (!cmd.stream_now) cmd.time_spec = usrp->get_time_now() + uhd::time_spec_t(0.1);
        rx->issue_stream_cmd(cmd);
        while (run) rx->recv(ptrs, rx->get_max_num_samps(), md, 0.1);
        rx->issue_stream_cmd(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS);
    });

    // Clear after the stream has started and the AD9361 has settled: starting
    // the stream produces a few full-scale samples that would pin the peak.
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    wr(64, 1);

    auto dbfs = [](unsigned p) { return p ? 20.0 * std::log10(p / 2048.0) : -999.0; };
    uint32_t prev[2] = {0, 0};
    uint64_t prev_s = 0;
    // The monitor sees the AD9361's two data slots. Measured on this board:
    // one channel streaming -> it is in slot 0; two channels -> UHD channel 0
    // is in slot 1 and channel 1 in slot 0.
    int slot_of[2] = {0, 1};
    if (ch.size() == 1) slot_of[ch[0]] = 0;
    else { slot_of[0] = 1; slot_of[1] = 0; }
    std::printf("\n%3s | %-38s | %-38s\n", "s", "UHD ch0 peak / over (new, rate) / sticky",
        "UHD ch1 peak / over (new, rate) / sticky");
    for (int n = 0; n < seconds; n++) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        const uint64_t s = rb(67) & 0xFFFFFFFFFFFFull;
        char col[2][64];
        for (int c = 0; c < 2; c++) {
            bool active = false;
            for (size_t k : ch) active |= (int(k) == c);
            if (!active) { std::snprintf(col[c], 64, "-"); continue; }
            const int sl = slot_of[c];
            const uint64_t r = rb(65 + sl);
            const uint32_t over = uint32_t(r >> 32), peak = uint32_t((r >> 16) & 0xfff);
            const bool sticky = (r >> 28) & 1;
            const double frac = (s > prev_s) ? double(over - prev[sl]) / double(s - prev_s) : 0.0;
            std::snprintf(col[c], 64, "%4u %6.1f dBFS / %u (+%u, %.2e) / %s", peak, dbfs(peak), over,
                over - prev[sl], frac, sticky ? "CLIPPED" : "ok");
            prev[sl] = over;
        }
        prev_s = s;
        std::printf("%3d | %-38s | %-38s\n", n, col[0], col[1]);
    }
    run = false;
    t.join();
    std::printf("threshold %u, samples since clear %llu\n", unsigned(rb(65) & 0xfff),
        (unsigned long long)(rb(67) & 0xFFFFFFFFFFFFull));
    return 0;
}
