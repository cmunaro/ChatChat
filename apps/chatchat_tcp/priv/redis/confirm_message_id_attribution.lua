local pending = redis.call('GET', KEYS[1]) -- get message data
if not pending then return 0 end

local message = cjson.decode(pending)
if message.message_id ~= ARGV[1] then return 0 end

local message_key = 'chatchat:message:' .. ARGV[1] -- chatchat:message:<message_id>
local receiver_set = 'chatchat:sending:' .. message.recipient_id -- chatchat:sending:<receiver_id>

redis.call('SET', message_key, pending)
redis.call('SADD', receiver_set, ARGV[1]) -- add message id to chatchat:sending:<receiver_id>
redis.call('ZADD', "chatchat:sending_deadlines", ARGV[2], ARGV[1]) -- add message id to sending_deadlines
redis.call('ZREM', 'chatchat:admission_reservations', KEYS[1])
redis.call('ZADD', 'chatchat:outstanding', ARGV[2], ARGV[1])
redis.call('DEL', KEYS[1]) -- delete chatchat:pending:<sender_id>:<request_id>
local presence_key = 'chatchat:presence:' .. message.recipient_id
local owners = redis.call('SMEMBERS', presence_key)
local published = 0
local stale = 0

for _, node_id in ipairs(owners) do
  if redis.call('EXISTS', 'chatchat:presence_node:' .. node_id) == 1 then
    redis.call('PUBLISH', 'chatchat:delivery:' .. node_id, message.recipient_id)
    published = published + 1
  else
    redis.call('SREM', presence_key, node_id)
    stale = stale + 1
  end
end

return {1, published, stale}
