#pragma once

#include "Biquad.hpp"

#include <cstdint>
#include <vector>

namespace echo::dsp {

/// ITU-R BS.1770-4 / EBU R128 loudness meter for offline analysis (SPEC § 6.7): K-weighting, 400 ms blocks with 75 %
/// overlap, absolute (−70 LUFS) and relative (−10 LU) gates; true peak by 4× oversampling. Allocates as it goes, so it
/// isn't for the render thread. Mono and stereo channels all weigh 1.0.
class LoudnessMeter {
public:
    void prepare(double sampleRate, int channelCount, bool measuresTruePeak);
    void process(const float* const* channels, int channelCount, int frameCount);
    /// Integrated loudness in LUFS; NaN when every block is gated out (e.g. silence).
    double integratedLUFS() const;
    /// True peak in dBTP; −infinity for digital silence.
    double truePeakDBTP() const;

    /// The K-weighting stages for `sampleRate` (pre-filter shelf, then RLB high-pass), in double precision.
    struct KWeighting {
        double b0, b1, b2, a1, a2;
    };
    static KWeighting preFilter(double sampleRate);
    static KWeighting highPass(double sampleRate);

private:
    struct Filter {
        KWeighting c;
        double z1 = 0, z2 = 0;
        double process(double x) {
            const double y = c.b0 * x + z1;
            z1 = c.b1 * x - c.a1 * y + z2;
            z2 = c.b2 * x - c.a2 * y;
            return y;
        }
    };

    void finishSubBlock();
    void measurePeak(const float* const* channels, int channelCount, int frameCount);

    int channelCount_ = 0;
    std::vector<Filter> pre_, rlb_;
    /// Sub-blocks are 100 ms; a block is four of them.
    int subBlockFrames_ = 4800;
    int subBlockFill_ = 0;
    double subBlockSum_ = 0;
    std::vector<double> recentSubBlocks_;
    /// Mean square (channel-weighted) of every 400 ms block.
    std::vector<double> blocks_;

    bool measuresTruePeak_ = true;
    int oversampling_ = 4;
    std::vector<float> phases_;     // oversampling_ × kTapsPerPhase
    std::vector<float> history_;    // per channel, kTapsPerPhase recent samples
    int historyPosition_ = 0;
    float peak_ = 0;

public:
    static constexpr int kTapsPerPhase = 12;
};

} // namespace echo::dsp
