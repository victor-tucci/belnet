#include <Foundation/Foundation.h>
#include <NetworkExtension/NetworkExtension.h>
#include "context_wrapper.h"
#include "DNSTrampoline.h"

@interface LLARPPacketTunnel : NEPacketTunnelProvider
{
  void* belnet;
  @public NEPacketTunnelNetworkSettings* settings;
  @public NEIPv4Route* tun_route4;
  @public NEIPv6Route* tun_route6;
  LLARPDNSTrampoline* dns_tramp;
}

- (void)startTunnelWithOptions:(NSDictionary<NSString*, NSObject*>*)options
             completionHandler:(void (^)(NSError* error))completionHandler;

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler;

- (void)handleAppMessage:(NSData*)messageData
       completionHandler:(void (^)(NSData* responseData))completionHandler;

- (void)readPackets;

- (void)updateNetworkSettings;

@end

static void nslogger(const char* msg) { NSLog(@"%s", msg); }

static void packet_writer(int af, const void* data, size_t size, void* ctx) {
  if (ctx == nil || data == nil)
    return;

  NSData* buf = [NSData dataWithBytesNoCopy:(void*)data length:size freeWhenDone:NO];
  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;
  NEPacket* packet = [[NEPacket alloc] initWithData:buf  protocolFamily: af];
  [t.packetFlow writePacketObjects:@[packet]];
}

static void start_packet_reader(void* ctx) {
  if (ctx == nil)
    return;

  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;
  [t readPackets];
}

static void add_ipv4_route(const char* addr, const char* netmask, void* ctx) {
  NEIPv4Route* route = [[NEIPv4Route alloc]
    initWithDestinationAddress: [NSString stringWithUTF8String:addr]
                    subnetMask: [NSString stringWithUTF8String:netmask]];

  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;
  for (NEIPv4Route* r in t->settings.IPv4Settings.includedRoutes)
    if ([r.destinationAddress isEqualToString:route.destinationAddress] &&
     [r.destinationSubnetMask isEqualToString:route.destinationSubnetMask])
      return; // Already in the settings, nothing to add.

  t->settings.IPv4Settings.includedRoutes =
    [t->settings.IPv4Settings.includedRoutes arrayByAddingObject:route];

  [t updateNetworkSettings];
}

static void del_ipv4_route(const char* addr, const char* netmask, void* ctx) {
  NEIPv4Route* route = [[NEIPv4Route alloc]
    initWithDestinationAddress: [NSString stringWithUTF8String:addr]
                    subnetMask: [NSString stringWithUTF8String:netmask]];

  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;
  NSMutableArray<NEIPv4Route*>* routes = [NSMutableArray arrayWithArray:t->settings.IPv4Settings.includedRoutes];
  for (int i = 0; i < routes.count; i++) {
    if ([routes[i].destinationAddress isEqualToString:route.destinationAddress] &&
        [routes[i].destinationSubnetMask isEqualToString:route.destinationSubnetMask]) {
      [routes removeObjectAtIndex:i];
      i--;
    }
  }

  if (routes.count != t->settings.IPv4Settings.includedRoutes.count) {
    t->settings.IPv4Settings.includedRoutes = routes;
    [t updateNetworkSettings];
  }
}

static void add_ipv6_route(const char* addr, int prefix, void* ctx) {
  NEIPv6Route* route = [[NEIPv6Route alloc]
    initWithDestinationAddress: [NSString stringWithUTF8String:addr]
           networkPrefixLength: [NSNumber numberWithInt:prefix]];

  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;
  for (NEIPv6Route* r in t->settings.IPv6Settings.includedRoutes)
    if ([r.destinationAddress isEqualToString:route.destinationAddress] &&
     [r.destinationNetworkPrefixLength isEqualToNumber:route.destinationNetworkPrefixLength])
      return; // Already in the settings, nothing to add.

  t->settings.IPv6Settings.includedRoutes =
    [t->settings.IPv6Settings.includedRoutes arrayByAddingObject:route];

  [t updateNetworkSettings];
}

static void del_ipv6_route(const char* addr, int prefix, void* ctx) {
  NEIPv6Route* route = [[NEIPv6Route alloc]
    initWithDestinationAddress: [NSString stringWithUTF8String:addr]
           networkPrefixLength: [NSNumber numberWithInt:prefix]];

  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;
  NSMutableArray<NEIPv6Route*>* routes = [NSMutableArray arrayWithArray:t->settings.IPv6Settings.includedRoutes];
  for (int i = 0; i < routes.count; i++) {
    if ([routes[i].destinationAddress isEqualToString:route.destinationAddress] &&
        [routes[i].destinationNetworkPrefixLength isEqualToNumber:route.destinationNetworkPrefixLength]) {
      [routes removeObjectAtIndex:i];
      i--;
    }
  }

  if (routes.count != t->settings.IPv6Settings.includedRoutes.count) {
    t->settings.IPv6Settings.includedRoutes = routes;
    [t updateNetworkSettings];
  }
}

static void add_default_route(void* ctx) {
  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;

  t->settings.IPv4Settings.includedRoutes = @[NEIPv4Route.defaultRoute];
  t->settings.IPv6Settings.includedRoutes = @[NEIPv6Route.defaultRoute];

  [t updateNetworkSettings];
}

static void del_default_route(void* ctx) {
  LLARPPacketTunnel* t = (__bridge LLARPPacketTunnel*) ctx;

  t->settings.IPv4Settings.includedRoutes = @[t->tun_route4];
  t->settings.IPv6Settings.includedRoutes = @[t->tun_route6];

  [t updateNetworkSettings];
}

@implementation LLARPPacketTunnel

- (void)readPackets
{
  [self.packetFlow readPacketObjectsWithCompletionHandler: ^(NSArray<NEPacket*>* packets) {
    if (belnet == nil)
      return;
    for (NEPacket* p in packets) {
      llarp_apple_incoming(belnet, p.data.bytes, p.data.length);
    }
    [self readPackets];
  }];
}

- (void)startTunnelWithOptions:(NSDictionary<NSString*, NSObject*>*)options
             completionHandler:(void (^)(NSError*))completionHandler
{
  NSString* default_bootstrap = [NSBundle.mainBundle pathForResource:@"bootstrap" ofType:@"signed"];
  NSString* home = NSHomeDirectory();

  llarp_apple_config conf = {
      .config_dir = home.UTF8String,
      .default_bootstrap = default_bootstrap.UTF8String,
      .ns_logger = nslogger,
      .packet_writer = packet_writer,
      .start_reading = start_packet_reader,
      .route_callbacks = {
          .add_ipv4_route = add_ipv4_route,
          .del_ipv4_route = del_ipv4_route,
          .add_ipv6_route = add_ipv6_route,
          .del_ipv6_route = del_ipv6_route,
          .add_default_route = add_default_route,
          .del_default_route = del_default_route
      },
  };

  belnet = llarp_apple_init(&conf);
  if (!belnet) {
    NSError *init_failure = [NSError errorWithDomain:error_domain code:500 userInfo:@{@"Error": @"Failed to initialize belnet"}];
    NSLog(@"%@", [init_failure localizedDescription]);
    return completionHandler(init_failure);
  }

  NSString* ip = [NSString stringWithUTF8String:conf.tunnel_ipv4_ip];
  NSString* mask = [NSString stringWithUTF8String:conf.tunnel_ipv4_netmask];

  // We don't have a fixed address so just stick some bogus value here:
  settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"127.3.2.1"];

  NEDNSSettings* dns = [[NEDNSSettings alloc] initWithServers:@[ip]];
  dns.domainName = @"localhost.bdx";
  dns.matchDomains = @[@""];
  // In theory, matchDomains is supposed to be set to DNS suffixes that we resolve.  This seems
  // highly unreliable, though: often it just doesn't work at all (perhaps only if we make ourselves
  // the default route?), and even when it does work, it seems there are secret reasons that some
  // domains (such as instagram.com) still won't work because there's some magic sauce in the OS
  // that Apple engineers don't want to disclose ("This is what I expected, actually. Although I
  // will not comment on what I believe is happening here", from
  // https://developer.apple.com/forums/thread/685410).
  //
  // So the documentation sucks and the feature doesn't appear to work, so as much as it would be
  // nice to capture only .bdx and .mnode when not in exit mode, we can't, so capture everything
  // and use our default upstream.
  dns.matchDomains = @[@""];
  dns.matchDomainsNoSearch = true;
  dns.searchDomains = @[];
  settings.DNSSettings = dns;

  NWHostEndpoint* upstreamdns_ep;
  if (strlen(conf.upstream_dns))
    upstreamdns_ep = [NWHostEndpoint endpointWithHostname:[NSString stringWithUTF8String:conf.upstream_dns] port:@(conf.upstream_dns_port).stringValue];

  NEIPv4Settings* ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[ip]
                                                       subnetMasks:@[mask]];
  tun_route4 = [[NEIPv4Route alloc] initWithDestinationAddress:ip subnetMask: mask];
  ipv4.includedRoutes = @[tun_route4];
  settings.IPv4Settings = ipv4;

  NSString* ip6 = [NSString stringWithUTF8String:conf.tunnel_ipv6_ip];
  NSNumber* ip6_prefix = [NSNumber numberWithUnsignedInt:conf.tunnel_ipv6_prefix];
  NEIPv6Settings* ipv6 = [[NEIPv6Settings alloc] initWithAddresses:@[ip6]
                                              networkPrefixLengths:@[ip6_prefix]];
  tun_route6 = [[NEIPv6Route alloc] initWithDestinationAddress:ip6
                                           networkPrefixLength:ip6_prefix];
  ipv6.includedRoutes = @[tun_route6];
  settings.IPv6Settings = ipv6;

  __weak LLARPPacketTunnel* weakSelf = self;
  [self setTunnelNetworkSettings:settings completionHandler:^(NSError* err) {
    if (err) {
      NSLog(@"Failed to configure belnet tunnel: %@", err);
      return completionHandler(err);
    }
    LLARPPacketTunnel* strongSelf = weakSelf;
    if (!strongSelf)
      return completionHandler(nil);

    int start_ret = llarp_apple_start(strongSelf->belnet, (__bridge void*) strongSelf);
    if (start_ret != 0) {
      NSError *start_failure = [NSError errorWithDomain:error_domain code:start_ret userInfo:@{@"Error": @"Failed to start belnet"}];
      NSLog(@"%@", start_failure);
      belnet = nil;
      return completionHandler(start_failure);
    }

    NSLog(@"Starting DNS exit mode trampoline to %@ on 127.0.0.1:%d", upstreamdns_ep, dns_trampoline_port);
    NWUDPSession* upstreamdns = [strongSelf createUDPSessionThroughTunnelToEndpoint:upstreamdns_ep fromEndpoint:nil];
    strongSelf->dns_tramp = [LLARPDNSTrampoline alloc];
    [strongSelf->dns_tramp
      startWithUpstreamDns:upstreamdns
                listenPort:dns_trampoline_port
                    uvLoop:llarp_apple_get_uv_loop(strongSelf->belnet)
         completionHandler:^(NSError* error) {
           if (error)
             NSLog(@"Error starting dns trampoline: %@", error);
           return completionHandler(error);
         }];
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler
{
  if (belnet) {
    llarp_apple_shutdown(belnet);
    belnet = nil;
  }
  completionHandler();
}

- (void)handleAppMessage:(NSData*)messageData
       completionHandler:(void (^)(NSData* responseData))completionHandler
{
  NSData* response = [NSData dataWithBytesNoCopy:"ok" length:3 freeWhenDone:NO];
  completionHandler(response);
}

- (void)updateNetworkSettings
{
  self.reasserting = YES;
  __weak LLARPPacketTunnel* weakSelf = self;
  // Apple documentation says that setting network settings to nil isn't required before setting it
  // to a new value.  Apple lies: both end up with a routing table that looks exactly the same (from
  // both `netstat -rn` and from everything that happens in `route -n monitor`), but if we don't
  // call with nil first then everything fails to route to either belnet *and* clearnet through the
  // exit, so there is apparently some special magic internal Apple state that actually *does*
  // require the tunnel settings being reset with nil first.
  //
  // Thanks for the accurate documentation, Apple.
  //
  [self setTunnelNetworkSettings:nil completionHandler:^(NSError* err) {
    if (err)
      NSLog(@"Failed to clear belnet tunnel settings: %@", err);
    LLARPPacketTunnel* strongSelf = weakSelf;
    if (strongSelf) {
      [weakSelf setTunnelNetworkSettings:strongSelf->settings completionHandler:^(NSError* err) {
        LLARPPacketTunnel* strongSelf = weakSelf;
        if (strongSelf)
          strongSelf.reasserting = NO;
        if (err)
          NSLog(@"Failed to reconfigure belnet tunnel settings: %@", err);
      }];
    }
  }];
}

@end
