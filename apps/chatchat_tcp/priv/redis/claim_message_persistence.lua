local score = redis.call('ZSCORE', KEYS[1], ARGV[1]) -- Get score of chatchat:sending_deadlines:message_id
if not score or tonumber(score) > tonumber(ARGV[2]) then return nil end -- return if not expired

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
redis.call('ZREM', KEYS[1], ARGV[1]) -- remove from sending_deadlines
redis.call('SADD', KEYS[2], ARGV[1]) -- add to persisting
return message
