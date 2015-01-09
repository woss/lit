exports.name = "creationix/websocket-codec"
exports.version = "0.1.2"

local digest = require('openssl').digest.digest
local base64 = require('openssl').base64
local random = require('openssl').random
local hexToBin = require('creationix/hex-bin').hexToBin

local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local rshift = bit.rshift
local lshift = bit.lshift
local char = string.char
local byte = string.byte
local sub = string.sub
local gmatch = string.gmatch
local lower = string.lower
local gsub = string.gsub
local concat = table.concat

local function applyMask(data, mask)
  local bytes = {
    [0] = byte(mask, 1),
    [1] = byte(mask, 2),
    [2] = byte(mask, 3),
    [3] = byte(mask, 4)
  }
  local out = {}
  for i = 1, #data do
    out[i] = char(
      bxor(byte(data, i), bytes[(i - 1) % 4])
    )
  end
  return concat(out)
end

function exports.decode(chunk)
  if #chunk < 2 then return end
  local second = byte(chunk, 2)
  local len = band(second, 0x7f)
  local offset
  if len == 126 then
    if #chunk < 4 then return end
    len = bor(
      lshift(byte(chunk, 3), 8),
      byte(chunk, 4))
    offset = 4
  elseif len == 127 then
    if #chunk < 10 then return end
    len = bor(
      lshift(byte(chunk, 3), 56),
      lshift(byte(chunk, 4), 48),
      lshift(byte(chunk, 5), 40),
      lshift(byte(chunk, 6), 32),
      lshift(byte(chunk, 7), 24),
      lshift(byte(chunk, 8), 16),
      lshift(byte(chunk, 9), 8),
      byte(chunk, 10))
    offset = 10
  else
    offset = 2
  end
  local mask = band(second, 0x80) > 0
  if mask then
    offset = offset + 4
  end
  if #chunk < offset + len - 1 then return end

  local first = byte(chunk, 1)
  local payload = sub(chunk, offset + 1, offset + len)
  if mask then
    payload = applyMask(payload, sub(chunk, offset - 3, offset))
  end
  local extra = sub(chunk, offset + len + 1)
  return {
    fin = band(first, 0x80) > 0,
    rsv1 = band(first, 0x40) > 0,
    rsv2 = band(first, 0x20) > 0,
    rsv3 = band(first, 0x10) > 0,
    opcode = band(first, 0xf),
    mask = mask,
    len = len,
    payload = payload
  }, extra
end

function exports.encode(item)
  if type(item) == "string" then
    item = {
      opcode = 2,
      payload = item
    }
  end
  local payload = item.payload
  assert(type(payload) == "string", "payload must be string")
  local len = #payload
  local fin = item.fin
  if fin == nil then fin = true end
  local rsv1 = item.rsv1
  local rsv2 = item.rsv2
  local rsv3 = item.rsv3
  local opcode = item.opcode or 2
  local mask = item.mask
  local chars = {
    char(bor(
      fin and 0x80 or 0,
      rsv1 and 0x40 or 0,
      rsv2 and 0x20 or 0,
      rsv3 and 0x10 or 0,
      opcode
    )),
    char(bor(
      mask and 0x80 or 0,
      len < 0x10 and len or len < 0x10000 and 126 or 127
    ))
  }
  if len >= 0x10000 then
    chars[3] = char(band(rshift(len, 56), 0xff))
    chars[4] = char(band(rshift(len, 48), 0xff))
    chars[5] = char(band(rshift(len, 40), 0xff))
    chars[6] = char(band(rshift(len, 32), 0xff))
    chars[7] = char(band(rshift(len, 24), 0xff))
    chars[8] = char(band(rshift(len, 16), 0xff))
    chars[9] = char(band(rshift(len, 8), 0xff))
    chars[10] = char(band(len, 0xff))
  elseif len >= 0x10 then
    chars[3] = char(band(rshift(len, 8), 0xff))
    chars[4] = char(band(len, 0xff))
  end
  if mask then
    local key = random(4)
    return concat(chars) .. key .. applyMask(payload, key)
  end
  return concat(chars) .. payload
end

local websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
function exports.handshake(head, protocol)

  -- Websocket connections must be GET requests
  if not head.method == "GET" then return end

  -- Parse the headers for quick reading
  local headers = {}
  for i = 1, #head do
    local name, value = unpack(head[i])
    headers[lower(name)] = value
  end

  -- Must have 'Upgrade: websocket' and 'Connection: Upgrade' headers
  if not (headers.upgrade and headers.connection
      and lower(headers.upgrade) == "websocket"
      and lower(headers.connection) == "upgrade"
  ) then return end

  -- Make sure it's a new client speaking v13 of the protocol
  if tonumber(headers["sec-websocket-version"]) < 13 then
    return nil, "only websocket protocol v13 supported"
  end

  local key = headers["sec-websocket-key"]
  if not key then
    return nil, "websocket security key missing"
  end

  -- If the server wants a specified protocol, check for it.
  if protocol then
    local foundProtocol = false
    local list = headers["sec-websocket-protocol"]
    if list then
      for item in gmatch(list, "[^, ]+") do
        if item == protocol then
          foundProtocol = true
          break
        end
      end
    end
    if not foundProtocol then
      return nil, "specified protocol missing in request"
    end
  end

  local accept = gsub(base64(hexToBin(digest("sha1", key .. websocketGuid))), "\n", "")

  local res = {
    code = 101,
    {"Upgrade", "websocket"},
    {"Connection", "Upgrade"},
    {"Sec-WebSocket-Accept", accept},
  }
  if protocol then
    res[#res + 1] = {"Sec-WebSocket-Protocol", protocol}
  end

  return res
end