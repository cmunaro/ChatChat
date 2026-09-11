local confirmed_message_id = redis.call('GET', KEYS[2])
if confirmed_message_id then
  if confirmed_message_id == ARGV[1] then return 1 end
  return 0
end

local pending = redis.call('GET', KEYS[1])
if not pending then return 0 end

local message = cjson.decode(pending)
if message.message_id ~= ARGV[1] then return 0 end

local sending_key = ARGV[4] .. message.recipient_id .. ':' .. ARGV[1]

redis.call('SET', sending_key, pending)
redis.call('ZADD', KEYS[3], ARGV[2], sending_key)
redis.call('SET', KEYS[2], ARGV[1], 'PX', ARGV[3])
redis.call('DEL', KEYS[1])
return 1
