local score = redis.call('ZSCORE', KEYS[1], ARGV[1])
if not score or tonumber(score) > tonumber(ARGV[2]) then return nil end

local message_key = 'chatchat:message:' .. ARGV[1]
local message = redis.call('GET', message_key)
if not message then
  redis.call('ZREM', KEYS[1], ARGV[1])
  return nil
end

local decoded = cjson.decode(message)
local persisting_key = 'chatchat:persisting:' .. ARGV[1]

redis.call('SET', persisting_key, message)
redis.call('DEL', message_key)
redis.call('SREM', 'chatchat:sending:' .. decoded.recipient_id, ARGV[1])
redis.call('ZREM', KEYS[1], ARGV[1])
redis.call('SADD', KEYS[2], ARGV[1])
return message
