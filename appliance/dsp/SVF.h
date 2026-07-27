// SVF.h — TPT (topology-preserving transform) state-variable filter, Andrew Simper /
// Cytomic form. The spec explicitly calls for TPT/SVF rather than static RBJ biquads
// anywhere the brain modulates parameters, because TPT filters are stable and
// zipper-free under continuous coefficient modulation. Used for the HPF and every
// parametric / shelf EQ band in the channel strip.
#pragma once
#include "DspConfig.h"
#include <cmath>
#include <algorithm>

namespace bdsp {

class SVF {
public:
    enum Type { LowPass, HighPass, BandPass, Notch, Bell, LowShelf, HighShelf };

    void reset(double sampleRate) {
        fs_ = sampleRate;
        ic1_ = ic2_ = 0.0;
    }

    // freq in Hz, Q dimensionless, gainDb only used for Bell/Shelf
    void set(Type type, double freq, double Q, double gainDb = 0.0) {
        const double f = std::min(0.49, freq / fs_);
        const double g = std::tan(M_PI * f);
        const double A = std::pow(10.0, gainDb / 40.0);
        double k;
        switch (type) {
            case Bell:
                k = 1.0 / (Q * A);
                setCore(g, k);
                m0_ = 1.0; m1_ = k * (A * A - 1.0); m2_ = 0.0;
                break;
            case LowShelf: {
                const double gs = g / std::sqrt(A);
                k = 1.0 / Q;
                setCore(gs, k);
                m0_ = 1.0; m1_ = k * (A - 1.0); m2_ = (A * A - 1.0);
                break;
            }
            case HighShelf: {
                const double gs = g * std::sqrt(A);
                k = 1.0 / Q;
                setCore(gs, k);
                m0_ = A * A; m1_ = k * (1.0 - A) * A; m2_ = (1.0 - A * A);
                break;
            }
            case LowPass:
                k = 1.0 / Q; setCore(g, k); m0_ = 0; m1_ = 0; m2_ = 1; break;
            case HighPass:
                k = 1.0 / Q; setCore(g, k); m0_ = 1; m1_ = -k; m2_ = -1; break;
            case BandPass:
                k = 1.0 / Q; setCore(g, k); m0_ = 0; m1_ = 1; m2_ = 0; break;
            case Notch:
                k = 1.0 / Q; setCore(g, k); m0_ = 1; m1_ = -k; m2_ = 0; break;
        }
    }

    inline float process(float in) {
        const double v0 = in;
        const double v3 = v0 - ic2_;
        const double v1 = a1_ * ic1_ + a2_ * v3;
        const double v2 = ic2_ + a2_ * ic1_ + a3_ * v3;
        ic1_ = 2.0 * v1 - ic1_;
        ic2_ = 2.0 * v2 - ic2_;
        return static_cast<float>(m0_ * v0 + m1_ * v1 + m2_ * v2);
    }

private:
    void setCore(double g, double k) {
        a1_ = 1.0 / (1.0 + g * (g + k));
        a2_ = g * a1_;
        a3_ = g * a2_;
    }
    double fs_ = kDefaultSampleRate;
    double a1_ = 0, a2_ = 0, a3_ = 0;
    double m0_ = 1, m1_ = 0, m2_ = 0;
    double ic1_ = 0, ic2_ = 0;
};

} // namespace bdsp
