// pps_probe: watch PPS edges as seen by the FPGA timekeeper and measure the
// board oscillator against them.
//
//   pps_probe [--args ARGS] [--fpga PATH] [--source external|gpsdo|internal] [--seconds N]
//             [--mcr HZ] [--clock internal|external|gpsdo]
//
// Each PPS edge latches the FPGA time into a register (get_time_last_pps).
// The latched time advances by (ticks counted between edges) / master_clock.
// If PPS is GPS-accurate, deviation from 1.000000000 s is the board
// oscillator's frequency error. Receive-only; nothing is transmitted.

#include <uhd/usrp/multi_usrp.hpp>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char** argv)
{
    std::string args   = "type=b200";
    std::string source = "external";
    int seconds        = 20;
    double mcr         = 30.72e6;
    std::string clock, fpga;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!std::strcmp(argv[i], "--args"))
            args = argv[i + 1];
        else if (!std::strcmp(argv[i], "--source"))
            source = argv[i + 1];
        else if (!std::strcmp(argv[i], "--seconds"))
            seconds = std::stoi(argv[i + 1]);
        else if (!std::strcmp(argv[i], "--mcr"))
            mcr = std::stod(argv[i + 1]);
        else if (!std::strcmp(argv[i], "--clock"))
            clock = argv[i + 1];
        else if (!std::strcmp(argv[i], "--fpga"))
            fpga = argv[i + 1];
    }
    if (!fpga.empty())
        args += ",fpga=" + fpga;

    auto usrp = uhd::usrp::multi_usrp::make(args + ",master_clock_rate=" + std::to_string(mcr));
    if (!clock.empty()) {
        usrp->set_clock_source(clock, 0);
        // Let the reference PLL / VCTCXO settle after a change
        std::this_thread::sleep_for(std::chrono::seconds(3));
    }
    std::printf("time sources: ");
    for (auto& s : usrp->get_time_sources(0))
        std::printf("%s ", s.c_str());
    std::printf("\nclock source: %s\n", usrp->get_clock_source(0).c_str());
    for (auto& s : usrp->get_mboard_sensor_names(0)) {
        // Raw NMEA carries the position: keep it out of logs. gps_servo exists
        // only on Ettus GPSDOs and throws for a generic NMEA GPS.
        if (s == "gps_gpgga" || s == "gps_gprmc") continue;
        try {
            std::printf("sensor %s = %s\n", s.c_str(),
                usrp->get_mboard_sensor(s, 0).to_pp_string().c_str());
        } catch (const std::exception& e) {
            std::printf("sensor %s unavailable (%s)\n", s.c_str(), e.what());
        }
    }

    usrp->set_time_source(source, 0);
    const double tick = 1.0 / usrp->get_master_clock_rate();
    std::printf("time source: %s  master clock: %.6f MHz\n", source.c_str(),
        usrp->get_master_clock_rate() / 1e6);

    // Wait for a first edge, up to 3 s
    auto t0 = usrp->get_time_last_pps(0);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (usrp->get_time_last_pps(0) == t0) {
        if (std::chrono::steady_clock::now() > deadline) {
            std::printf("NO PPS EDGES seen on source '%s' in 3 s\n", source.c_str());
            return 1;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    auto last = usrp->get_time_last_pps(0);
    std::vector<double> ppm;
    int missing = 0;
    std::printf("%4s %18s %14s %12s\n", "n", "last_pps (s)", "delta-1 (ticks)", "err (ppm)");
    for (int n = 0; n < seconds;) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        auto now = usrp->get_time_last_pps(0);
        if (now == last) {
            if (++missing > 100) { // ~2 s with no new edge
                std::printf("PPS stopped\n");
                break;
            }
            continue;
        }
        missing        = 0;
        double delta   = (now - last).get_real_secs();
        double dticks  = (delta - 1.0) / tick;
        double err_ppm = (delta - 1.0) * 1e6;
        std::printf("%4d %18.9f %14.1f %12.4f%s\n", n, now.get_real_secs(), dticks,
            err_ppm, std::fabs(delta - 1.0) > 0.01 ? "  <-- not 1 s apart" : "");
        if (std::fabs(delta - 1.0) < 0.01)
            ppm.push_back(err_ppm);
        last = now;
        n++;
    }

    if (!ppm.empty()) {
        double mean = 0, var = 0;
        for (double p : ppm) mean += p;
        mean /= ppm.size();
        for (double p : ppm) var += (p - mean) * (p - mean);
        std::printf("\n%zu intervals: mean %.4f ppm, std %.4f ppm (1 tick = %.4f ppm)\n",
            ppm.size(), mean, std::sqrt(var / ppm.size()), tick * 1e6);
    }
    return 0;
}
