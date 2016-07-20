module(..., package.seeall)

local constants = require("apps.lwaftr.constants")
local lwutil = require("apps.lwaftr.lwutil")
local shm = require("core.shm")

local transmit, receive = link.transmit, link.receive
local rd16, rd32 = lwutil.rd16, lwutil.rd32

local ethernet_header_size = constants.ethernet_header_size
local n_ethertype_ipv4 = constants.n_ethertype_ipv4
local o_ethernet_ethertype = constants.o_ethernet_ethertype
local o_ipv4_dst_addr = constants.o_ipv4_dst_addr
local o_ipv4_src_addr = constants.o_ipv4_src_addr
local ipv6_fixed_header_size = constants.ipv6_fixed_header_size

local v4v6_mirror = shm.create("v4v6_mirror", "struct { uint32_t ipv4; }")

local function is_ipv4 (pkt)
   return rd16(pkt.data + o_ethernet_ethertype) == n_ethertype_ipv4
end
local function get_ethernet_payload (pkt)
   return pkt.data + ethernet_header_size
end
local function get_ipv4_dst_num (ptr)
   return rd32(ptr + o_ipv4_dst_addr)
end
local function get_ipv4_src_num (ptr)
   return rd32(ptr + o_ipv4_src_addr)
end
local function get_ipv6_payload (ptr)
   return ptr + ipv6_fixed_header_size
end

local function mirror_ipv4 (pkt, output, ipv4_num)
   local ipv4_hdr = get_ethernet_payload(pkt)
   if get_ipv4_dst_num(ipv4_hdr) == ipv4_num or
         get_ipv4_src_num(ipv4_hdr) == ipv4_num then
      transmit(output, packet.clone(pkt))
   end
end

local function mirror_ipv6 (pkt, output, ipv4_num)
   local ipv6_hdr = get_ethernet_payload(pkt)
   local ipv4_hdr = get_ipv6_payload(ipv6_hdr)
   if get_ipv4_dst_num(ipv4_hdr) == ipv4_num or
         get_ipv4_src_num(ipv4_hdr) == ipv4_num then
      transmit(output, packet.clone(pkt))
   end
end

v4v6 = {}

function v4v6:new (conf)
   local o = {
      description = conf.description or "v4v6",
      mirror = conf.mirror or false,
   }
   return setmetatable(o, {__index = v4v6})
end

function v4v6:push()
   local input, output = self.input.input, self.output.output
   local v4_tx, v6_tx = self.output.v4_tx, self.output.v6_tx
   local v4_rx, v6_rx = self.input.v4_rx, self.input.v6_rx
   local mirror = self.output.mirror

   local ipv4_num
   if self.mirror then
      mirror = self.output.mirror
      ipv4_num = v4v6_mirror.ipv4
   end

   -- Split input to IPv4 and IPv6 traffic.
   if input then
      while not link.empty(input) do
         local pkt = receive(input)
         if is_ipv4(pkt) then
            if mirror then
               mirror_ipv4(pkt, mirror, ipv4_num)
            end
            transmit(v4_tx, pkt)
         else
            if mirror then
               mirror_ipv6(pkt, mirror, ipv4_num)
            end
            transmit(v6_tx, pkt)
         end
      end
   end

   -- Join IPv4 and IPv6 traffic to output.
   if output then
      while not link.empty(v4_rx) do
         local pkt = receive(v4_rx)
         if mirror and not link.full(mirror) then
            mirror_ipv4(pkt, mirror, ipv4_num)
         end
         transmit(output, pkt)
      end
      while not link.empty(v6_rx) do
         local pkt = receive(v6_rx)
         if mirror then
            mirror_ipv6(pkt, mirror, ipv4_num)
         end
         transmit(output, pkt)
      end
   end
end

-- Tests.

local function ipv4_pkt ()
   local lib = require("core.lib")
   return packet.from_string(lib.hexundump([[
      02 aa aa aa aa aa 02 99 99 99 99 99 08 00 45 00
      02 18 00 00 00 00 0f 11 d3 61 0a 0a 0a 01 c1 05
      01 64 30 39 14 00 00 20 00 00 00 00 00 00 00 00
      00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
      00 00
   ]], 66))
end

local function ipv6_pkt ()
   local lib = require("core.lib")
   return packet.from_string(lib.hexundump([[
      02 aa aa aa aa aa 02 99 99 99 99 99 86 dd 60 00
      01 f0 01 f0 04 ff fc 00 00 01 00 02 00 03 00 04
      00 05 00 00 44 2d fc 00 00 00 00 00 00 00 00 00
      00 00 00 00 01 00 45 00 01 f0 00 00 00 00 0f 11
      d2 76 c1 05 02 77 0a 0a 0a 01 0c 00 30 39 00 20
      00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
      00 00 00 00 00 00 00 00 00 00
   ]], 106))
end

local function test_split ()
   local basic_apps = require("apps.basic.basic_apps")
   engine.configure(config.new()) -- Clean up engine.

   local c = config.new()
   config.app(c, 'source', basic_apps.Join)
   config.app(c, 'v4v6', v4v6)
   config.app(c, 'sink', basic_apps.Sink)

   config.link(c, 'source.output -> v4v6.input')
   config.link(c, 'v4v6.v4_tx -> sink.in1')
   config.link(c, 'v4v6.v6_tx -> sink.in2')

   engine.configure(c)
   link.transmit(engine.app_table.source.output.output, ipv4_pkt())
   link.transmit(engine.app_table.source.output.output, ipv6_pkt())
   engine.main({duration = 0.1, noreport = true})

   assert(link.stats(engine.app_table.sink.input.in1).rxpackets == 1)
   assert(link.stats(engine.app_table.sink.input.in2).rxpackets == 1)
end

local function test_join ()
   local basic_apps = require("apps.basic.basic_apps")
   engine.configure(config.new()) -- Clean up engine.

   local c = config.new()
   config.app(c, 'source', basic_apps.Join)
   config.app(c, 'v4v6', v4v6)
   config.app(c, 'sink', basic_apps.Sink)

   config.link(c, 'source.output -> v4v6.v4_rx')
   config.link(c, 'source.output -> v4v6.v6_rx')
   config.link(c, 'v4v6.output -> sink.input')

   engine.configure(c)
   link.transmit(engine.app_table.source.output.output, ipv4_pkt())
   link.transmit(engine.app_table.source.output.output, ipv6_pkt())
   engine.main({duration = 0.1, noreport = true})

   assert(link.stats(engine.app_table.sink.input.input).rxpackets == 2)
end

function selftest ()
   print("v4v6: selftest")
   test_split()
   test_join()
   print("OK")
end
