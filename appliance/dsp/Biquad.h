// Biquad.h — transposed-direct-form-II biquad for FIXED filters (the K-weighting
// stages of the loudness meter). For anything the brain modulates we use the TPT SVF
// instead; biquads are fine where coefficients never move.
#pragma once
#include <array>
#include <cmath>

namespace bdsp {

class Biquad {
public:
    void setCoeffs(double b0, double b1, double b2, double a1, double a2) {
        b0_ = b0; b1_ = b1; b2_ = b2; a1_ = a1; a2_ = a2;
    }
    void reset() { z1_ = z2_ = 0.0; }

    inline double process(double x) {
        const double y = b0_ * x + z1_;
        z1_ = b1_ * x - a1_ * y + z2_;
        z2_ = b2_ * x - a2_ * y;
        return y;
    }

private:
    double b0_ = 1, b1_ = 0, b2_ = 0, a1_ = 0, a2_ = 0;
    double z1_ = 0, z2_ = 0;
};

// ITU-R BS.1770-4 K-weighting (pre-filter + RLB high-pass).
struct KWeighting {
    Biquad shelf, hp;
    void reset(double sampleRate) {
        // De Man coefficients from the BS.1770 K-weighting reference design,
        // generated for the active sample rate. At 48 kHz these match the
        // previously hardcoded constants exactly.
        const double shelfFc = 1681.974450955533;
        const double shelfGainDb = 3.999843853973347;
        const double shelfQ = 0.7071752369554196;
        const double shelfK = std::tan(pi() * shelfFc / sampleRate);
        const double vh = std::pow(10.0, shelfGainDb / 20.0);
        const double vb = std::pow(vh, 0.499666774155);
        const double shelfA0 = 1.0 + shelfK / shelfQ + shelfK * shelfK;
        shelf.setCoeffs(
            (vh + vb * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            2.0 * (shelfK * shelfK - vh) / shelfA0,
            (vh - vb * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            2.0 * (shelfK * shelfK - 1.0) / shelfA0,
            (1.0 - shelfK / shelfQ + shelfK * shelfK) / shelfA0);

        const double hpFc = 38.13547087602444;
        const double hpQ = 0.5003270373238773;
        const double hpK = std::tan(pi() * hpFc / sampleRate);
        const double hpA0 = 1.0 + hpK / hpQ + hpK * hpK;
        hp.setCoeffs(1.0, -2.0, 1.0,
                     2.0 * (hpK * hpK - 1.0) / hpA0,
                     (1.0 - hpK / hpQ + hpK * hpK) / hpA0);
        shelf.reset();
        hp.reset();
    }
    inline double process(double x) { return hp.process(shelf.process(x)); }

private:
    static constexpr double pi() { return 3.14159265358979323846264338327950288; }
};

} // namespace bdsp
