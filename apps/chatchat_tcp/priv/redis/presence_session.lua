-- Compare the complete owner/session value; expired leases cannot be renewed.
local operation = ARGV[1]
local owner = ARGV[2]
local ttl = ARGV[3]

if operation == 'acquire' then
  if not redis.call('SET', KEYS[1], owner, 'NX', 'PX', ttl) then
    return 0
  end
  redis.call('SET', KEYS[2], '1', 'PX', ttl)
  return 1
end

if redis.call('GET', KEYS[1]) ~= owner then
  return 0
end

if operation == 'renew' then
  redis.call('PEXPIRE', KEYS[1], ttl)
  return 1
end

if operation == 'release' then
  redis.call('DEL', KEYS[1])
  return 1
end

return redis.error_reply('invalid presence operation')
