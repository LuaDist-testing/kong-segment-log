local basic_serializer = require "kong.plugins.log-serializers.basic"
local BasePlugin = require "kong.plugins.base_plugin"
local jwt_decoder = require "kong.plugins.segment-log.jwt_parser"
local cjson = require "cjson"
local url = require "socket.url"
local base64 = require "base64"

local SegmentLogHandler = BasePlugin:extend()

SegmentLogHandler.PRIORITY = 1

local HTTPS = "https"

-- Generates http payload .
-- @param `method` http method to be used to send data
-- @param `parsed_url` contains the host details
-- @param `authorization` The authorization header
-- @return `body` http payload
local function generate_http_payload(method, parsed_url, authorization, body)
  return string.format(
    "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: Keep-Alive\r\nContent-Type: application/json\r\nContent-Length: %s\r\nAuthorization: %s\r\n\r\n%s",
    method:upper(), parsed_url.path, parsed_url.host, authorization, string.len(body), body)
end

-- Parse host url
-- @param `url`  host url
-- @return `parsed_url`  a table with host details like domain name, port, path etc
local function parse_url(host_url)
  local parsed_url = url.parse(host_url)
  if not parsed_url.port then
    if parsed_url.scheme == "http" then
      parsed_url.port = 80
     elseif parsed_url.scheme == HTTPS then
      parsed_url.port = 443
     end
  end
  if not parsed_url.path then
    parsed_url.path = "/"
  end
  return parsed_url
end

-- Log to a Http end point.
-- @param `premature`
-- @param `conf`     Configuration table, holds http endpoint details
-- @param `body`  Log data
-- @param `name`  The name of this logging plugin. Used as prefix for any nginx log output from this function.
local function log(premature, conf, body, name)
  if premature then return end
  if not name then
    name = 'segment-log'
  end
  name = "["..name.."] "

  local ok, err
  local parsed_url = parse_url('https://api.segment.io/v1/track')
  local host = parsed_url.host
  local port = tonumber(parsed_url.port)

  local authorization = body.request.headers.authorization
  if not authorization then
    ngx.log(ngx.ERR, name.."failed to track user activity due to missing Authorization header.")
    return
  end

  -- Decode token to find out who the consumer is
  local bearer_token = string.gsub(authorization, '^%w+ ', '')
  local jwt, err = jwt_decoder:new(bearer_token)
  if err then
    ngx.log(ngx.ERR, name.."failed to decode Authorization token: ", err)
    return
  end

  local user_id = jwt.claims[conf.jwt_payload_key__user_id]
  if not user_id then
    ngx.log(ngx.ERR, name.."failed to find property `"..conf.jwt_payload_key__user_id.."` in decoded Authorization token payload.")
    return
  end

  local sock = ngx.socket.tcp()
  sock:settimeout(conf.timeout)

  ok, err = sock:connect(host, port)
  if not ok then
    ngx.log(ngx.ERR, name.."failed to connect to "..host..":"..tostring(port)..": ", err)
    return
  end

  if parsed_url.scheme == HTTPS then
    local _, err = sock:sslhandshake(true, host, false)
    if err then
      ngx.log(ngx.ERR, name.."failed to do SSL handshake with "..host..":"..tostring(port)..": ", err)
    end
  end

  local event_path = body.request.uri
  if conf.glob_event_name_paths then
    event_path = string.gsub(event_path, '[^/]*[0-9]+[^/]*', '*')
  end

  -- "authenticated_entity": {
  --       "consumer_id": "80f74eef-31b8-45d5-c525-ae532297ea8e",
  --       "created_at":   1437643103000,
  --       "id": "eaa330c0-4cff-47f5-c79e-b2e4f355207e",
  --       "key": "2b64e2f0193851d4135a2e885cd08a65"
  --   },

  local track_data = {
    userId = user_id,
    event = body.request.method.." "..event_path,
    properties = {
      method = body.request.method,
      path = body.request.uri,
      uri = body.request.request_uri,
      querystring = cjson.encode(body.request.querystring),
      timeOfProxy = body.latencies.proxy,
      timeOfKong = body.latencies.kong,
      timeOfRequest = body.latencies.request,
      statusCode = body.response.status
    },
    context = {
      ip = body.client_ip,
      userAgent = body.request.headers['user-agent']
    },
    timestamp = os.date("!%Y-%m-%dT%TZ", body.started_at / 1000)
  }
  local track_body = cjson.encode(track_data)

  ok, err = sock:send(generate_http_payload('POST', parsed_url, 'Basic ' + base64.encode(conf.segment_write_key..':'), track_body))
  if not ok then
    ngx.log(ngx.ERR, name.."failed to send data to "..host..":"..tostring(port)..": ", err)
  end

  ok, err = sock:setkeepalive(conf.keepalive)
  if not ok then
    ngx.log(ngx.ERR, name.."failed to keepalive to "..host..":"..tostring(port)..": ", err)
    return
  end
end

-- Only provide `name` when deriving from this class. Not when initializing an instance.
function SegmentLogHandler:new(name)
  SegmentLogHandler.super.new(self, name or "segment-log")
end

-- serializes context data into an html message body
-- @param `ngx` The context table for the request being logged
-- @return html body as string
function SegmentLogHandler:serialize(ngx)
  -- return cjson.encode(basic_serializer.serialize(ngx))
  return basic_serializer.serialize(ngx)
end

function SegmentLogHandler:log(conf)
  SegmentLogHandler.super.log(self)

  local ok, err = ngx.timer.at(0, log, conf, self:serialize(ngx), self._name)
  if not ok then
    ngx.log(ngx.ERR, "["..self._name.."] failed to create timer: ", err)
  end
end

return SegmentLogHandler
