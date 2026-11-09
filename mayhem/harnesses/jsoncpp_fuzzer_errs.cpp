// jsoncpp_fuzzer for the mined build: the upstream harness at this commit parses with errs == nullptr,
// so Reader/OurReader::getFormattedErrorMessages() is never reached. This one passes an errs string,
// as callers of CharReader::parse() that report errors do, and sets each setting by its valid name.
#include <cstdint>
#include <cstdlib>
#include <json/json.h>
#include <memory>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  Json::CharReaderBuilder builder;

  if (size < sizeof(uint32_t)) {
    return 0;
  }

  const uint32_t hash_settings = static_cast<uint32_t>(data[0]) |
                                 (static_cast<uint32_t>(data[1]) << 8) |
                                 (static_cast<uint32_t>(data[2]) << 16) |
                                 (static_cast<uint32_t>(data[3]) << 24);
  data += sizeof(uint32_t);
  size -= sizeof(uint32_t);

  builder.settings_["failIfExtra"] = (hash_settings & (1 << 0)) != 0;
  builder.settings_["allowComments"] = (hash_settings & (1 << 1)) != 0;
  builder.settings_["strictRoot"] = (hash_settings & (1 << 2)) != 0;
  builder.settings_["allowDroppedNullPlaceholders"] =
      (hash_settings & (1 << 3)) != 0;
  builder.settings_["allowNumericKeys"] = (hash_settings & (1 << 4)) != 0;
  builder.settings_["allowSingleQuotes"] = (hash_settings & (1 << 5)) != 0;
  builder.settings_["skipBom"] = (hash_settings & (1 << 6)) != 0;
  builder.settings_["rejectDupKeys"] = (hash_settings & (1 << 7)) != 0;
  builder.settings_["allowSpecialFloats"] = (hash_settings & (1 << 8)) != 0;
  builder.settings_["collectComments"] = (hash_settings & (1 << 9)) != 0;
  builder.settings_["allowTrailingCommas"] = (hash_settings & (1 << 10)) != 0;

  std::unique_ptr<Json::CharReader> reader(builder.newCharReader());

  Json::Value root;
  std::string errs;
  const auto data_str = reinterpret_cast<const char*>(data);
  try {
    reader->parse(data_str, data_str + size, &root, &errs);
  } catch (Json::Exception const&) {
  }
  return 0;
}
