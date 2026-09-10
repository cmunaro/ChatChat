  local sending = redis.call('GET', KEYS[2])
  if sending then
    if cjson.decode(sending).message_id == ARGV[1] then
      return 1
    end
    return 0
  end

  local pending = redis.call('GET', KEYS[1])
  if not pending or cjson.decode(pending).message_id ~= ARGV[1] then
    return 0
  end

  redis.call('SET', KEYS[2], pending)
  redis.call('ZADD', KEYS[3], ARGV[2], ARGV[1])
  redis.call('DEL', KEYS[1])
  return 1
  