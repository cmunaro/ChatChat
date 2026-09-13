if redis.call('SISMEMBER', KEYS[1], ARGV[1]) == 0 then return 0 end

-- check if message data exists chatchat:message:<message_id>
if redis.call('EXISTS', KEYS[2]) == 0 then return 0 end

redis.call('DEL', KEYS[2]) -- delete message data
redis.call('SREM', KEYS[1], ARGV[1]) -- remove message id from pendings
redis.call('ZREM', "chatchat:sending_deadlines", ARGV[1]) -- remove from deadlines
return 1
