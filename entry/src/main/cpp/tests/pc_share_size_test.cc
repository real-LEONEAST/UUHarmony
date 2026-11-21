#include "../pc_host/share_size.h"

#include <cassert>

void CheckSize(int width, int height, int width_alignment, int height_alignment, int w, int h) {
  const auto result = uu::pc::SmoothShareSize(width, height, width_alignment, height_alignment);
  assert(result.width == w && result.height == h);
}

int main() {
  CheckSize(3120, 2080, 2, 2, 1620, 1080);
  CheckSize(3120, 2080, 16, 16, 1584, 1056);
  CheckSize(3120, 2080, 64, 64, 1536, 1024);
  CheckSize(2080, 3120, 2, 2, 1080, 1620);
  CheckSize(3840, 2160, 2, 2, 1920, 1080);
  CheckSize(1280, 720, 2, 2, 1280, 720);
  CheckSize(2560, 1080, 2, 2, 1920, 810);
  CheckSize(3119, 2079, 2, 2, 1620, 1080);
}
