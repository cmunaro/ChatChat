local pending = redis.call('GET', KEYS[1]) -- get message data
if not pending then return 0 end

local message = cjson.decode(pending)
if message.message_id ~= ARGV[1] then return 0 end

local message_key = 'chatchat:message:' .. ARGV[1] -- chatchat:message:<message_id>
local receiver_set = 'chatchat:sending:' .. message.recipient_id -- chatchat:sending:<receiver_id>

redis.call('SET', message_key, pending)
redis.call('SADD', receiver_set, ARGV[1]) -- add message id to chatchat:sending:<receiver_id>
redis.call('ZADD', KEYS[2], ARGV[2], ARGV[1]) -- add message id to sending_deadlines
redis.call('DEL', KEYS[1]) -- delete chatchat:{admission}:pending:<sender_id>:<request_id>
redis.call('PUBLISH', 'chatchat:delivery', message.recipient_id) -- notify delivery worker
return 1
