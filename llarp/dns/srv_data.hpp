#pragma once

#include "name.hpp"
#include "serialize.hpp"

#include <tuple>
#include <string_view>

#include "llarp/util/status.hpp"

namespace llarp::dns
{
  typedef std::tuple<std::string, uint16_t, uint16_t, uint16_t, std::string> SRVTuple;

  struct SRVData
  {
    static constexpr size_t TARGET_MAX_SIZE = 200;

    std::string service_proto;  // service and protocol may as well be together

    uint16_t priority;
    uint16_t weight;
    uint16_t port;

    // target string for the SRV record to point to
    // options:
    //   empty                     - refer to query name
    //   dot                       - authoritative "no such service available"
    //   any other .bdx or .mnode - target is that .bdx or .mnode
    std::string target;

    // do some basic validation on the target string
    // note: this is not a conclusive, regex solution,
    // but rather some sanity/safety checks
    bool
    IsValid() const;

    SRVTuple
    toTuple() const;

    /// so we can put SRVData in a std::set
    bool
    operator<(const SRVData& other) const
    {
      return service_proto < other.service_proto or priority < other.priority
          or weight < other.weight or port < other.port or target < other.target;
    }

    bool
    operator==(const SRVData& other) const
    {
      return service_proto == other.service_proto and priority == other.priority
          and weight == other.weight and port == other.port and target == other.target;
    }

    bool
    BEncode(llarp_buffer_t*) const;

    bool
    BDecode(llarp_buffer_t*);

    util::StatusObject
    ExtractStatus() const;

    static SRVData
    fromTuple(SRVTuple tuple);

    /* bind-like formatted string for SRV records in config file
     *
     * format:
     *   srv=service.proto priority weight port target
     *
     * exactly one space character between parts.
     *
     * target can be empty, in which case the space after port should
     * be omitted.  if this is the case, the target is
     * interpreted as the .bdx or .mnode of the current context.
     *
     * if target is not empty, it must be either
     *  - simply a full stop (dot/period) OR
     *  - a name within the .bdx or .mnode subdomains. a target
     *    specified in this manner must not end with a full stop.
     */
    bool
    fromString(std::string_view srvString);
  };

}  // namespace llarp::dns

namespace std
{
  template <>
  struct hash<llarp::dns::SRVData>
  {
    size_t
    operator()(const llarp::dns::SRVData& data) const
    {
      const std::hash<std::string> h_str{};
      const std::hash<uint16_t> h_port{};
      return h_str(data.service_proto) ^ (h_str(data.target) << 3) ^ (h_port(data.priority) << 5)
          ^ (h_port(data.weight) << 7) ^ (h_port(data.port) << 9);
    }
  };
}  // namespace std
