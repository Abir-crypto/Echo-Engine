#pragma once

namespace echo::dsp {

/// A parameter that moves linearly to its target over a fixed number of frames, so changes never click.
class SmoothedValue {
public:
    void reset(float value) noexcept {
        current_ = target_ = value;
        step_ = 0;
        remaining_ = 0;
    }

    void setTarget(float target, int rampFrames) noexcept {
        if (rampFrames <= 0) {
            reset(target);
            return;
        }
        target_ = target;
        remaining_ = rampFrames;
        step_ = (target_ - current_) / static_cast<float>(rampFrames);
    }

    /// The value for the next frame.
    float next() noexcept {
        if (remaining_ > 0) {
            current_ += step_;
            if (--remaining_ == 0) { current_ = target_; }
        }
        return current_;
    }

    /// Skips `frames` frames at once (block-rate parameters such as filter coefficients).
    void advance(int frames) noexcept {
        if (remaining_ <= 0) { return; }
        if (frames >= remaining_) {
            current_ = target_;
            remaining_ = 0;
        } else {
            current_ += step_ * static_cast<float>(frames);
            remaining_ -= frames;
        }
    }

    float current() const noexcept { return current_; }
    float target() const noexcept { return target_; }
    bool isSmoothing() const noexcept { return remaining_ > 0; }

private:
    float current_ = 0;
    float target_ = 0;
    float step_ = 0;
    int remaining_ = 0;
};

} // namespace echo::dsp
