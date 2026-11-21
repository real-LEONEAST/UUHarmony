#ifndef UU_PC_HOST_SHARE_SIZE_H
#define UU_PC_HOST_SHARE_SIZE_H

#include <algorithm>
#include <numeric>

namespace uu::pc {
struct ShareSize {
  int width;
  int height;
};

// Keep the long edge within 1920 and the short edge within 1080.
inline ShareSize SmoothShareSize(int width, int height, int width_alignment, int height_alignment) {
  const int max_width = std::min(width, width >= height ? 1920 : 1080);
  const int max_height = std::min(height, width >= height ? 1080 : 1920);
  const int divisor = std::gcd(width, height);
  const int unit_width = width / divisor;
  const int unit_height = height / divisor;
  const int alignment = std::lcm(width_alignment / std::gcd(unit_width, width_alignment),
                                 height_alignment / std::gcd(unit_height, height_alignment));
  const int max_multiplier = std::min(max_width / unit_width, max_height / unit_height);
  const int multiplier = max_multiplier / alignment * alignment;
  // Prefer an exact aspect ratio when the alignment leaves a size near the target.
  if (multiplier > 0 && multiplier * 10 >= max_multiplier * 9) {
    return {unit_width * multiplier, unit_height * multiplier};
  }
  const double scale = std::min(double(max_width) / width, double(max_height) / height);
  return {int(width * scale + 1e-6) / width_alignment * width_alignment,
          int(height * scale + 1e-6) / height_alignment * height_alignment};
}
}

#endif
