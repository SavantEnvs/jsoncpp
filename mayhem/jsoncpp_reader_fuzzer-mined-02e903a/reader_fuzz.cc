// Legacy Json::Reader (deprecated, still public): parse(std::istream&), then its error reporting.
// Input: 4 settings bytes (same prefix as upstream's fuzz.cpp), then the document.
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

#include <json/json.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < sizeof(uint32_t)) {
    return -1;
  }
  const uint32_t settings = static_cast<uint32_t>(data[0]) |
                            (static_cast<uint32_t>(data[1]) << 8) |
                            (static_cast<uint32_t>(data[2]) << 16) |
                            (static_cast<uint32_t>(data[3]) << 24);
  data += sizeof(uint32_t);
  size -= sizeof(uint32_t);

  Json::Features features;
  features.allowComments_ = settings & (1 << 0);
  features.strictRoot_ = settings & (1 << 1);
  features.allowDroppedNullPlaceholders_ = settings & (1 << 2);
  features.allowNumericKeys_ = settings & (1 << 3);

  std::istringstream is(std::string(reinterpret_cast<const char*>(data), size));
  Json::Reader reader(features);
  Json::Value root;
  reader.parse(is, root, settings & (1 << 4));
  // Public API, documented as valid after parse(): reads the document the reader points into.
  std::string messages = reader.getFormattedErrorMessages();
  std::vector<Json::Reader::StructuredError> errors = reader.getStructuredErrors();
  return messages.size() + errors.size() > (1u << 30) ? 1 : 0;
}
