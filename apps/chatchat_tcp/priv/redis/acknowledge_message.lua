if redis.call('SISMEMBER', KEYS[1], ARGV[1]) == 0 then return 0 end

if redis.call('EXISTS', KEYS[2]) == 0 then return 0 end

redis.call('DEL', KEYS[2])
redis.call('SREM', KEYS[1], ARGV[1])
redis.call('ZREM', KEYS[3], ARGV[1])
return 1
