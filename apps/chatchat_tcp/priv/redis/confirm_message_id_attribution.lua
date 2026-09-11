local pending = redis.call('GET', KEYS[1])
if not pending then return 0 end

local message = cjson.decode(pending)
if message.message_id ~= ARGV[1] then return 0 end

local message_key = ARGV[3] .. ARGV[1]
local receiver_set = ARGV[4] .. message.recipient_id

redis.call('SET', message_key, pending)
redis.call('SADD', receiver_set, ARGV[1])
redis.call('ZADD', KEYS[2], ARGV[2], ARGV[1])
redis.call('DEL', KEYS[1])
redis.call('PUBLISH', ARGV[5], message.recipient_id)
return 1
