// Json::Reader (the legacy, deprecated reader) over std::istream, then its error-reporting methods.
#include <cstdint>
#include <cstddef>
#include <sstream>
#include <string>

#include <json/json.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  std::istringstream is(std::string(reinterpret_cast<const char*>(data), size));
  Json::Reader reader;
  Json::Value root;
  reader.parse(is, root);
  // Public API, valid after parse(): reads the document the reader still points into.
  std::string msgs = reader.getFormattedErrorMessages();
  (void)reader.getStructuredErrors();
  return msgs.size() > (1u << 30) ? 1 : 0;
}
