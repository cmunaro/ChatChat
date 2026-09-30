local reservations = 'chatchat:admission_reservations'
local outstanding = 'chatchat:outstanding'
local expired = redis.call('ZRANGEBYSCORE', reservations, '-inf', ARGV[1], 'LIMIT', 0, 256)

for _, key in ipairs(expired) do
  redis.call('ZREM', reservations, key)
end

local existing = redis.call('ZSCORE', reservations, KEYS[1])

if not existing and redis.call('ZCARD', reservations) + redis.call('ZCARD', outstanding) >= tonumber(ARGV[3]) then
  return 0
end

redis.call('SET', KEYS[1], ARGV[4], 'PX', ARGV[2])
redis.call('ZADD', reservations, tonumber(ARGV[1]) + tonumber(ARGV[2]), KEYS[1])
redis.call('PUBLISH', 'chatchat:admin:messages', ARGV[5])
return 1
