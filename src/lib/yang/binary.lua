-- Use of this source code is governed by the Apache 2.0 license; see
-- COPYING.
module(..., package.seeall)

local ffi = require("ffi")
local schema = require("lib.yang.schema")
local util = require("lib.yang.util")
local value = require("lib.yang.value")
local stream = require("lib.yang.stream")
local data = require('lib.yang.data')
local ctable = require('lib.ctable')

local MAGIC = "yangconf"
local VERSION = 0x00001000

local header_t = ffi.typeof([[
struct {
   uint8_t magic[8];
   uint32_t version;
   uint64_t source_mtime_sec;
   uint32_t source_mtime_nsec;
   uint32_t schema_name;
   uint32_t revision_date;
   uint32_t data_start;
   uint32_t data_len;
   uint32_t strtab_start;
   uint32_t strtab_len;
}
]])

-- A string table is written out as a uint32 count, followed by that
-- many offsets indicating where the Nth string ends, followed by the
-- string data for those strings.
local function string_table_builder()
   local strtab = {}
   local strings = {}
   local count = 0
   function strtab:intern(str)
      if strings[str] then return strings[str] end
      strings[str] = count
      count = count + 1
      return strings[str]
   end
   function strtab:emit(stream)
      local by_index = {}
      for str, idx in pairs(strings) do by_index[idx] = str end
      stream:align(4)
      local strtab_start = stream.written
      stream:write_uint32(count)
      local str_end = 0
      for i=0,count-1 do
         str_end = str_end + by_index[i]:len()
         stream:write_uint32(str_end)
      end
      for i=0,count-1 do
         str_end = str_end + by_index[i]:len()
         stream:write(by_index[i], by_index[i]:len())
      end
      return strtab_start, stream.written - strtab_start
   end
   return strtab
end

local function read_string_table(stream, strtab_len)
   assert(strtab_len >= 4)
   local count = stream:read_uint32()
   assert(strtab_len >= (4 * (count + 1)))
   local offsets = stream:read_array(ffi.typeof('uint32_t'), count)
   assert(strtab_len == (4 * (count + 1)) + offsets[count-1])
   local strings = {}
   local offset = 0
   for i=0,count-1 do
      local len = offsets[i] - offset
      assert(len >= 0)
      strings[i] = ffi.string(stream:read(len), len)
      offset = offset + len
   end
   return strings
end

local value_emitters = {}
local function value_emitter(ctype)
   if value_emitters[ctype] then return value_emitters[ctype] end
   local type = ffi.typeof(ctype)
   local align = ffi.alignof(type)
   local size = ffi.sizeof(type)
   local buf = ffi.typeof('$[1]', type)()
   local function emit(val, stream)
      buf[0] = val
      stream:write_ptr(buf)
   end
   value_emitters[ctype] = emit
   return emit
end

local function table_size(tab)
   local size = 0
   for k,v in pairs(tab) do size = size + 1 end
   return size
end

local function data_emitter(production)
   local handlers = {}
   local function visit1(production)
      return assert(handlers[production.type])(production)
   end
   local function visitn(productions)
      local ret = {}
      for keyword,production in pairs(productions) do
         ret[keyword] = visit1(production)
      end
      return ret
   end
   function handlers.struct(production)
      local member_names = {}
      for k,_ in pairs(production.members) do table.insert(member_names, k) end
      table.sort(member_names)
      if production.ctype then
         return function(data, stream)
            stream:write_stringref('cdata')
            stream:write_stringref(production.ctype)
            stream:write_ptr(data)
         end
      else
         local emit_member = visitn(production.members)
         local normalize_id = data.normalize_id
         return function(data, stream)
            stream:write_stringref('lstruct')
            stream:write_uint32(table_size(data))
            for _,k in ipairs(member_names) do
               local id = normalize_id(k)
               if data[id] ~= nil then
                  stream:write_stringref(id)
                  emit_member[k](data[id], stream)
               end
            end
         end
      end
   end
   function handlers.array(production)
      if production.ctype then
         local emit_value = value_emitter(production.ctype)
         return function(data, stream)
            stream:write_stringref('carray')
            stream:write_stringref(production.ctype)
            stream:write_uint32(#data)
            stream:write_array(data.ptr, ffi.typeof(production.ctype), #data)
         end
      else
         local emit_tagged_value = visit1(
            {type='scalar', argument_type=production.element_type})
         return function(data, stream)
            stream:write_stringref('larray')
            stream:write_uint32(#data)
            for i=1,#data do emit_tagged_value(data[i], stream) end
         end
      end
   end
   function handlers.table(production)
      if production.key_ctype and production.value_ctype then
         return function(data, stream)
            stream:write_stringref('ctable')
            stream:write_stringref(production.key_ctype)
            stream:write_stringref(production.value_ctype)
            data:save(stream)
         end
      elseif production.string_key then
         local emit_value = visit1({type='struct', members=production.values,
                                    ctype=production.value_ctype})
         -- FIXME: sctable if production.value_ctype?
         return function(data, stream)
            -- A string-keyed table is the same as a tagged struct.
            stream:write_stringref('lstruct')
            stream:write_uint32(table_size(data))
            for k,v in pairs(data) do
               stream:write_stringref(k)
               emit_value(v, stream)
            end
         end
      elseif production.key_ctype then
         local emit_keys = visit1({type='table', key_ctype=production.key_ctype,
                                   value_ctype='uint32_t'})
         local emit_value = visit1({type='struct', members=production.values})
         return function(data, stream)
            stream:write_stringref('cltable')
            emit_keys(data.keys)
            stream:write_uint32(#data.values)
            for i=1,#data.values do emit_value(data.values[i], stream) end
         end
      else
         local emit_key = visit1({type='struct', members=production.keys,
                                  ctype=production.key_ctype})
         local emit_value = visit1({type='struct', members=production.values,
                                    ctype=production.value_ctype})
         -- FIXME: lctable if production.value_ctype?
         return function(data, stream)
            stream:write_stringref('lltable')
            stream:write_uint32(table_count(data))
            for k,v in pairs(data) do
               emit_key(k, stream)
               emit_value(v, stream)
            end
         end
      end
   end
   function handlers.scalar(production)
      local primitive_type = production.argument_type.primitive_type
      -- FIXME: needs a case for unions
      if primitive_type == 'string' then
         return function(data, stream)
            stream:write_stringref('stringref')
            stream:write_stringref(data)
         end
      else
         local ctype = assert(assert(value.types[primitive_type]).ctype)
         local emit_value = value_emitter(ctype)
         return function(data, stream)
            stream:write_stringref('cdata')
            stream:write_stringref(ctype)
            emit_value(data, stream)
         end
      end
   end

   return visit1(production)
end

function data_compiler_from_grammar(emit_data, schema_name, schema_revision)
   return function(data, filename, source_mtime)
      source_mtime = source_mtime or {sec=0, nsec=0}
      local stream = stream.open_temporary_output_byte_stream(filename)
      local strtab = string_table_builder()
      local header = header_t(
         MAGIC, VERSION, source_mtime.sec, source_mtime.nsec,
         strtab:intern(schema_name), strtab:intern(schema_revision or ''))
      stream:write_ptr(header) -- Write with empty data_len etc, fix it later.
      header.data_start = stream.written
      local u32buf = ffi.new('uint32_t[1]')
      function stream:write_uint32(val)
         u32buf[0] = val
         return self:write_ptr(u32buf)
      end
      function stream:write_stringref(str)
         return self:write_uint32(strtab:intern(str))
      end
      emit_data(data, stream)
      header.data_len = stream.written - header.data_start
      header.strtab_start, header.strtab_len = strtab:emit(stream)
      stream:rewind()
      -- Fix up header.
      stream:write_ptr(header)
      stream:close_and_rename()
   end
end

function data_compiler_from_schema(schema)
   local grammar = data.data_grammar_from_schema(schema)
   return data_compiler_from_grammar(data_emitter(grammar),
                                     schema.id, schema.revision_date)
end

function compile_data_for_schema(schema, data, filename, source_mtime)
   return data_compiler_from_schema(schema)(data, filename, source_mtime)
end

function compile_data_for_schema_by_name(schema_name, data, filename, source_mtime)
   return compile_data_for_schema(schema.load_schema_by_name(schema_name),
                                  data, filename, source_mtime)
end

local function read_compiled_data(stream, strtab)
   local function read_string()
      return assert(strtab[stream:read_uint32()])
   end
   local ctypes = {}
   local function scalar_type(ctype)
      if not ctypes[ctype] then ctypes[ctype] = ffi.typeof(ctype) end
      return ctypes[ctype]
   end

   local readers = {}
   local function read1()
      local tag = read_string()
      return assert(readers[tag], tag)()
   end
   function readers.lstruct()
      local ret = {}
      for i=1,stream:read_uint32() do
         local k = read_string()
         ret[k] = read1()
      end
      return ret
   end
   function readers.carray()
      local ctype = scalar_type(read_string())
      local count = stream:read_uint32()
      return util.ffi_array(stream:read_array(ctype, count), ctype, count)
   end
   function readers.larray()
      local ret = {}
      for i=1,stream:read_uint32() do table.insert(ret, read1()) end
      return ret
   end
   function readers.ctable()
      local key_ctype = read_string()
      local value_ctype = read_string()
      local key_t, value_t = ffi.typeof(key_ctype), ffi.typeof(value_ctype)
      return ctable.load(stream, {key_type=key_t, value_type=value_t})
   end
   function readers.cltable()
      local keys = read1()
      local values = {}
      for i=1,stream:read_uint32() do table.insert(values, read1()) end
      return cltable.build(keys, values)
   end
   function readers.lltable()
      local ret = data.make_assoc()
      for i=1,stream:read_uint32() do
         local k = read1()
         ret:add(k, read1())
      end
      return ret
   end
   function readers.stringref()
      return read_string()
   end
   function readers.cdata()
      local ctype = scalar_type(read_string())
      return stream:read_ptr(ctype)[0]
   end
   return read1()
end

function has_magic(stream)
   local success, header = pcall(stream.read_ptr, stream, header_t)
   stream:seek(0)
   return success and ffi.string(header.magic, ffi.sizeof(header.magic)) == MAGIC
end

function load_compiled_data(stream)
   local uint32_t = ffi.typeof('uint32_t')
   function stream:read_uint32()
      return stream:read_ptr(uint32_t)[0]
   end
   local header = stream:read_ptr(header_t)
   assert(ffi.string(header.magic, ffi.sizeof(header.magic)) == MAGIC,
          "expected file to begin with "..MAGIC)
   assert(header.version == VERSION,
          "incompatible version: "..header.version)
   stream:seek(header.strtab_start)
   local strtab = read_string_table(stream, header.strtab_len)
   local ret = {}
   ret.schema_name = strtab[header.schema_name]
   ret.revision_date = strtab[header.revision_date]
   ret.source_mtime = {sec=header.source_mtime_sec,
                       nsec=header.source_mtime_nsec}
   stream:seek(header.data_start)
   ret.data = read_compiled_data(stream, strtab)
   assert(stream:seek() == header.data_start + header.data_len)
   return ret
end

function load_compiled_data_file(filename)
   return load_compiled_data(stream.open_input_byte_stream(filename))
end

function selftest()
   print('selfcheck: lib.yang.binary')
   local test_schema = schema.load_schema([[module snabb-simple-router {
      namespace snabb:simple-router;
      prefix simple-router;

      import ietf-inet-types {prefix inet;}

      leaf is-active { type boolean; default true; }

      leaf-list integers { type uint32; }
      container routes {
         presence true;
         list route {
            key addr;
            leaf addr { type inet:ipv4-address; mandatory true; }
            leaf port { type uint8 { range 0..11; } mandatory true; }
         }
      }
   }]])
   local data = data.load_data_for_schema(test_schema, [[
      is-active true;
      integers 1;
      integers 2;
      integers 0xffffffff;
      routes {
        route { addr 1.2.3.4; port 1; }
        route { addr 2.3.4.5; port 10; }
        route { addr 3.4.5.6; port 2; }
      }
   ]])

   local ipv4 = require('lib.protocol.ipv4')

   for i=1,3 do
      assert(data.is_active == true)
      assert(#data.integers == 3)
      assert(data.integers[1] == 1)
      assert(data.integers[2] == 2)
      assert(data.integers[3] == 0xffffffff)
      local routing_table = data.routes.route
      assert(routing_table:lookup_ptr(ipv4:pton('1.2.3.4')).value.port == 1)
      assert(routing_table:lookup_ptr(ipv4:pton('2.3.4.5')).value.port == 10)
      assert(routing_table:lookup_ptr(ipv4:pton('3.4.5.6')).value.port == 2)

      local tmp = os.tmpname()
      compile_data_for_schema(test_schema, data, tmp)
      local data2 = load_compiled_data_file(tmp)
      assert(data2.schema_name == 'snabb-simple-router')
      assert(data2.revision_date == '')
      data = data2.data
      os.remove(tmp)
   end
   print('selfcheck: ok')
end
