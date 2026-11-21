#pragma once
#include <cstdint>

namespace s5video {
// UU desktop capture reports its acquisition orientation. Restore upright pixels
// with the inverse angle. T5 calibrated the decoder's clockwise API separately
// from the source; do not invert RTP metadata or alter the remote display mode.
constexpr bool ValidOrientation(uint32_t value) { return value < 8; }
constexpr int PresentationDegrees(uint32_t value) { return ((4 - (value & 3)) & 3) * 90; }
constexpr int NativeTransform(uint32_t value)
{
    constexpr int transforms[8] = {0, 1, 2, 3, 4, 6, 8, 10};
    return ValidOrientation(value) ? transforms[value] : -1;
}
constexpr bool SwapsAxes(uint32_t value) { return (value & 1) != 0; }
constexpr int DisplayWidth(int width, int height, uint32_t value) { return SwapsAxes(value) ? height : width; }
constexpr int DisplayHeight(int width, int height, uint32_t value) { return SwapsAxes(value) ? width : height; }
}
