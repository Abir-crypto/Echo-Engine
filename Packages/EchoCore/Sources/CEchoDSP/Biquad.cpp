#include "Biquad.hpp"

#include <algorithm>
#include <cmath>
#include <complex>

namespace echo::dsp {

BiquadCoefficients makeBiquad(FilterShape shape, double sampleRate, double frequency, double gainDB, double q) noexcept {
    if (shape == FilterShape::bypass) { return {}; }
    const double f = std::clamp(frequency, 10.0, 0.49 * sampleRate);
    const double w0 = 2.0 * M_PI * f / sampleRate;
    const double cosw = std::cos(w0), sinw = std::sin(w0);
    const double alpha = sinw / (2.0 * std::max(q, 0.01));
    const double A = std::pow(10.0, gainDB / 40.0);
    const double sqrtA2alpha = 2.0 * std::sqrt(A) * alpha;
    double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;

    switch (shape) {
    case FilterShape::peaking:
        b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A;
        a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A;
        break;
    case FilterShape::lowShelf:
        b0 = A * ((A + 1) - (A - 1) * cosw + sqrtA2alpha);
        b1 = 2 * A * ((A - 1) - (A + 1) * cosw);
        b2 = A * ((A + 1) - (A - 1) * cosw - sqrtA2alpha);
        a0 = (A + 1) + (A - 1) * cosw + sqrtA2alpha;
        a1 = -2 * ((A - 1) + (A + 1) * cosw);
        a2 = (A + 1) + (A - 1) * cosw - sqrtA2alpha;
        break;
    case FilterShape::highShelf:
        b0 = A * ((A + 1) + (A - 1) * cosw + sqrtA2alpha);
        b1 = -2 * A * ((A - 1) + (A + 1) * cosw);
        b2 = A * ((A + 1) + (A - 1) * cosw - sqrtA2alpha);
        a0 = (A + 1) - (A - 1) * cosw + sqrtA2alpha;
        a1 = 2 * ((A - 1) - (A + 1) * cosw);
        a2 = (A + 1) - (A - 1) * cosw - sqrtA2alpha;
        break;
    case FilterShape::bandPass:
        b0 = alpha; b1 = 0; b2 = -alpha;
        a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha;
        break;
    case FilterShape::bypass:
        break;
    }
    return {
        static_cast<float>(b0 / a0), static_cast<float>(b1 / a0), static_cast<float>(b2 / a0),
        static_cast<float>(a1 / a0), static_cast<float>(a2 / a0),
    };
}

double biquadMagnitudeDB(const BiquadCoefficients& c, double sampleRate, double frequency) noexcept {
    const std::complex<double> z1 = std::polar(1.0, -2.0 * M_PI * frequency / sampleRate);
    const std::complex<double> z2 = z1 * z1;
    const std::complex<double> numerator = double(c.b0) + double(c.b1) * z1 + double(c.b2) * z2;
    const std::complex<double> denominator = 1.0 + double(c.a1) * z1 + double(c.a2) * z2;
    return 20.0 * std::log10(std::abs(numerator) / std::abs(denominator));
}

} // namespace echo::dsp
