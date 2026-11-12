local redis = require "resty.redis"
local cjson = require "cjson.safe"

local PassportRouter = {
  VERSION = "1.1.0",
  PRIORITY = 900,
}

local function csv(value)
  if value == nil then
    return ""
  end
  if type(value) == "table" then
    return table.concat(value, ",")
  end
  return tostring(value)
end

-- Paths that should print "log me" to the Kong console (error log).
-- Kong PDK kong.request.get_path() returns the normalized request path,
-- e.g. "/NWC/rest/Login".
local LOGIN_PATHS = {
  ["/NWC/rest/Login"] = true,
  ["/AGENT/rest/Login"] = true,
}

local function is_login_path(path)
  return LOGIN_PATHS[path] == true
end

-- Returns the profile object from passport.profiles that has the newest
-- (most recent) lastUpdated date. Dates are expected in "YYYY-MM-DD HH:MM:SS"
-- format, which compares correctly as plain strings. Returns nil when there
-- are no profiles or none carry a lastUpdated field.
local function newest_profile_by_last_updated(profiles)
  if not profiles or type(profiles) ~= "table" then
    return nil
  end
  local newest_profile = nil
  local newest_date = nil
  for _, p in ipairs(profiles) do
    if type(p) == "table" then
      local lu = p.lastUpdated
      if lu and (newest_date == nil or lu > newest_date) then
        newest_date = lu
        newest_profile = p
      end
    end
  end
  return newest_profile
end

function PassportRouter:access(conf)
  -- Step 1: Get MSISDN from header (defined in plugin config as msisdn_header)
  local msisdn = kong.request.get_header(conf.msisdn_header)
  if msisdn == nil or msisdn == "" then
    return kong.response.exit(400, { message = "MSISDN header is required" })
  end

  -- Step 2: Lookup Passport in Redis. Get key: passport:<msisdn>
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    kong.log.err("passport-router: redis connect failed: ", err)
    return kong.response.exit(503, { message = "Passport service unavailable" })
  end

  local key = conf.passport_prefix .. msisdn
  local res, err = red:get(key)

  if err then
    kong.log.err("passport-router: redis GET failed for key ", key, ": ", err)
    local keepalive_ok, keepalive_err = red:set_keepalive()
    if not keepalive_ok then
      kong.log.warn("passport-router: redis keepalive failed: ", keepalive_err)
    end
    return kong.response.exit(503, { message = "Passport service unavailable" })
  end
  kong.log.info("passport-router: msisdn=", msisdn, " key=", key, " res=", tostring(res), " err=", tostring(err))
  if res == ngx.null or res == nil or res == "" then
    local keepalive_ok, keepalive_err = red:set_keepalive()
    if not keepalive_ok then
      kong.log.warn("passport-router: redis keepalive failed: ", keepalive_err)
    end
    return kong.response.exit(404, { message = "Passport not found" })
  end

  local passport, json_err = cjson.decode(res)
  if not passport then
    kong.log.err("passport-router: passport JSON decode failed: ", json_err)
    local keepalive_ok, keepalive_err = red:set_keepalive()
    if not keepalive_ok then
      kong.log.warn("passport-router: redis keepalive failed: ", keepalive_err)
    end
    return kong.response.exit(503, { message = "Passport service unavailable" })
  end

  -- Step 3: Get routing decision.
  -- Check device-specific default first (AC-11), fall back to global passport.defaultRoute
  local device_id = kong.request.get_header("X-Device-Id")
  local device_route = nil
  if device_id and device_id ~= "" and passport.deviceDefaults and type(passport.deviceDefaults) == "table" then
    for _, dd in ipairs(passport.deviceDefaults) do
      if dd.deviceId and string.lower(dd.deviceId) == string.lower(device_id) then
        if dd.route and dd.route ~= "" then
          device_route = dd.route
          break
        end
      end
    end
  end

  local route = device_route or passport.defaultRoute

  -- Store login request info for later update after successful response.
  local req_path = kong.request.get_path()
  if is_login_path(req_path) then
    kong.ctx.shared.is_login_path = true
    kong.ctx.shared.passport_key = key
    kong.ctx.shared.passport = passport
    kong.ctx.shared.msisdn = msisdn
    kong.ctx.shared.device_id = device_id
  else
    kong.ctx.shared.is_login_path = false
  end

  -- Return connection to pool regardless of outcome
  local keepalive_ok, keepalive_err = red:set_keepalive()
  if not keepalive_ok then
    kong.log.warn("passport-router: redis keepalive failed: ", keepalive_err)
  end

  if route == nil or route == "" then
    return kong.response.exit(400, { message = "No defaultRoute found in Passport" })
  end
  route = string.upper(route)

  -- Step 4: Determine target upstream
  local upstream
  if route == "NORTH" then
    upstream = conf.north_upstream
  elseif route == "SOUTH" then
    upstream = conf.south_upstream
  else
    return kong.response.exit(400, { message = "Unsupported defaultRoute" })
  end

  -- Step 5: Find matching profile. Search passport.profiles for route,
  -- extract accountId, persona, personaId
  local profile = nil
  if passport.profiles and type(passport.profiles) == "table" then
    for _, p in ipairs(passport.profiles) do
      local r = p.route or p.region -- region accepted for backward compatibility
      if r and string.upper(r) == route then
        profile = p
        break
      end
    end
  end
  if not profile then
    return kong.response.exit(404, { message = "Profile not found for route: " .. route })
  end
  kong.log.info("passport-router: defaultRoute=", route, " -> upstream=", upstream, " accountId=", tostring(profile.accountId), " deviceId=", tostring(device_id))

  -- Step 6: Set trusted headers for backend (added by Kong, not trusted from client)
  kong.service.request.set_header("X-Region", route)
  kong.service.request.set_header("X-Account-Id", tostring(profile.accountId or ""))
  kong.service.request.set_header("X-Persona", csv(profile.persona))
  kong.service.request.set_header("X-Persona-Id", csv(profile.personaId or profile.personaID))
  kong.service.request.set_header("X-Passport-Guid", tostring(passport.guid or ""))
  if device_id and device_id ~= "" then
    kong.service.request.set_header("X-Device-Id", device_id)
  end

  -- Store region + transform config for the response phases (header_filter / body_filter)
  kong.ctx.shared.region = route
  kong.ctx.shared.response_transform_enabled = conf.response_transform_enabled
  kong.ctx.shared.add_region_response_header = conf.add_region_response_header
  kong.ctx.shared.north_field_map = conf.north_field_map
  kong.ctx.shared.south_field_map = conf.south_field_map
  kong.ctx.shared.north_add_fields = conf.north_add_fields
  kong.ctx.shared.south_add_fields = conf.south_add_fields
  kong.ctx.shared.north_delete_fields = conf.north_delete_fields
  kong.ctx.shared.south_delete_fields = conf.south_delete_fields
  kong.ctx.shared.north_add_headers = conf.north_add_headers
  kong.ctx.shared.south_add_headers = conf.south_add_headers
  kong.ctx.shared.north_delete_headers = conf.north_delete_headers
  kong.ctx.shared.south_delete_headers = conf.south_delete_headers

  -- Store dynamic values for placeholder resolution in add_fields
  kong.ctx.shared.dyn_msisdn = msisdn or ""
  kong.ctx.shared.dyn_account_id = tostring(profile.accountId or "")
  kong.ctx.shared.dyn_guid = tostring(passport.guid or "")

  -- Step 7: Select upstream via kong.service.set_upstream(upstream), check return value
  local set_ok, set_err = kong.service.set_upstream(upstream)
  if not set_ok then
    kong.log.err("passport-router: set_upstream failed for ", upstream, ": ", set_err)
    return kong.response.exit(503, { message = "Backend routing unavailable" })
  end

  -- Request forwarded to backend with trusted headers and selected upstream.
end

-- HEADER phase: add/delete response headers based on region, and strip Content-Length so
-- the body can be rewritten in body_filter without a length mismatch.
function PassportRouter:header_filter(conf)
  local region = kong.ctx.shared.region

  -- Add per-region response headers (key-value pairs, supports {placeholders})
  local add_json = (region == "NORTH") and kong.ctx.shared.north_add_headers or kong.ctx.shared.south_add_headers
  local add_headers
  local json_err
  if add_json and add_json ~= "" and add_json ~= "{}" then
    add_headers, json_err = cjson.decode(add_json)
    if not add_headers then
      kong.log.warn("passport-router: header_filter: invalid add_headers JSON for region ", region, ": ", tostring(json_err))
    end
  end

  if type(add_headers) == "table" then
    for header_name, header_value in pairs(add_headers) do
      local resolved = header_value
      if type(header_value) == "string" then
        resolved = header_value
          :gsub("{region}", region or "")
          :gsub("{msisdn}", kong.ctx.shared.dyn_msisdn or "")
          :gsub("{accountId}", kong.ctx.shared.dyn_account_id or "")
          :gsub("{guid}", kong.ctx.shared.dyn_guid or "")
      end
      kong.response.set_header(header_name, resolved)
    end
  end

  -- Delete per-region response headers (array of header names)
  local del_json = (region == "NORTH") and kong.ctx.shared.north_delete_headers or kong.ctx.shared.south_delete_headers
  local delete_headers
  local json_err
  if del_json and del_json ~= "" and del_json ~= "{}" then
    delete_headers, json_err = cjson.decode(del_json)
    if not delete_headers then
      kong.log.warn("passport-router: header_filter: invalid delete_headers JSON for region ", region, ": ", tostring(json_err))
    end
  end

  if type(delete_headers) == "table" then
    for _, header_name in ipairs(delete_headers) do
      ngx.header[header_name] = nil
    end
  end

  -- Add X-Response-Region header if enabled
  if kong.ctx.shared.add_region_response_header then
    if region then
      kong.response.set_header("X-Response-Region", region)
      kong.response.set_header("X-API-Key", "12334444")
    end
  end

  if kong.ctx.shared.response_transform_enabled then
    -- kong.response.remove_header does not exist in Kong 3.8; use ngx.header instead.
    ngx.header["Content-Length"] = nil
  end
end

-- BODY phase: buffer the full response body, then on the last chunk transform
-- north/south-specific field names into a common format using the per-region
-- field map from config. Also annotates the body with _region.
function PassportRouter:body_filter(conf)
  if not kong.ctx.shared.response_transform_enabled then
    return
  end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]

  local buffer = kong.ctx.shared.response_body or ""
  if chunk and chunk ~= "" then
    buffer = buffer .. chunk
  end
  kong.ctx.shared.response_body = buffer

  -- Not the last chunk: suppress this chunk and wait for the rest.
  if not eof then
    ngx.arg[1] = nil
    return
  end

  local region = kong.ctx.shared.region
  if not region then
    ngx.arg[1] = buffer
    return
  end

  -- Only transform JSON bodies.
  local body, json_err = cjson.decode(buffer)
  if not body then
    kong.log.warn("passport-router: body_filter: non-JSON or empty body (region=", region, "): ", tostring(json_err))
    ngx.arg[1] = buffer
    return
  end

  -- Detect business-level login success (errorNo == 0) BEFORE field map
  -- renames errorNo/error -> errorNumber.
  if kong.ctx.shared.is_login_path and body.errorNo == 0 then
    kong.ctx.shared.login_success = true
    -- Schedule async Redis update via ngx.timer.at because network I/O
    -- (TCP sockets) is blocked in the body_filter_by_lua* context.
    local timer_data = {
      redis_host    = conf.redis_host,
      redis_port    = conf.redis_port,
      redis_timeout = conf.redis_timeout,
      passport      = kong.ctx.shared.passport,
      key           = kong.ctx.shared.passport_key,
      msisdn        = kong.ctx.shared.msisdn,
      region        = kong.ctx.shared.region,
      device_id     = kong.ctx.shared.device_id,
    }
    local timer_ok, timer_err = ngx.timer.at(0, function(premature, data)
      if premature then return end
      local red_t = redis:new()
      red_t:set_timeout(data.redis_timeout)
      local conn_ok, conn_err = red_t:connect(data.redis_host, data.redis_port)
      if not conn_ok then
        ngx.log(ngx.ERR, "passport-router: async redis connect failed: ", conn_err)
        return
      end
      if data.passport then
        local now = os.date("%Y-%m-%d %H:%M:%S")
        data.passport.lastUpdated = now
        data.passport.defaultRoute = data.region

        -- Update per-device default if device_id is present (AC-11)
        if data.device_id and data.device_id ~= "" then
          if not data.passport.deviceDefaults or type(data.passport.deviceDefaults) ~= "table" then
            data.passport.deviceDefaults = {}
          end
          local found = false
          for _, dd in ipairs(data.passport.deviceDefaults) do
            if dd.deviceId and string.lower(dd.deviceId) == string.lower(data.device_id) then
              dd.route = data.region
              dd.lastUpdated = now
              found = true
              break
            end
          end
          if not found then
            table.insert(data.passport.deviceDefaults, {
              deviceId = data.device_id,
              route = data.region,
              lastUpdated = now
            })
          end
        end

        local set_ok, set_err = red_t:set(data.key, cjson.encode(data.passport))
        if not set_ok then
          ngx.log(ngx.ERR, "passport-router: async failed to persist last_update for msisdn=", data.msisdn, ": ", set_err)
        else
          ngx.log(ngx.INFO, "passport-router: async updated passport object=", cjson.encode(data.passport), " for msisdn=", data.msisdn)
        end
      end
      red_t:set_keepalive()
    end, timer_data)
    if not timer_ok then
      kong.log.err("passport-router: failed to create timer for async last_update: ", timer_err)
    end
  end

  -- Pick the per-region field map: { common_name = source_name, ... }
  local map_json = (region == "NORTH") and kong.ctx.shared.north_field_map or kong.ctx.shared.south_field_map
  local field_map
  if map_json and map_json ~= "" and map_json ~= "{}" then
    field_map, json_err = cjson.decode(map_json)
    if not field_map then
      kong.log.warn("passport-router: body_filter: invalid field map JSON for region ", region, ": ", tostring(json_err))
    end
  end

  if type(field_map) == "table" then
    for common_name, source_name in pairs(field_map) do
      if body[source_name] ~= nil then
        body[common_name] = body[source_name]
        body[source_name] = nil
      end
    end
  end

  -- Delete per-region fields from the response body.
  local del_json = (region == "NORTH") and kong.ctx.shared.north_delete_fields or kong.ctx.shared.south_delete_fields
  local delete_fields
  if del_json and del_json ~= "" and del_json ~= "{}" then
    delete_fields, json_err = cjson.decode(del_json)
    if not delete_fields then
      kong.log.warn("passport-router: body_filter: invalid delete_fields JSON for region ", region, ": ", tostring(json_err))
    end
  end

  if type(delete_fields) == "table" then
    for _, field_name in ipairs(delete_fields) do
      body[field_name] = nil
    end
  end

  -- Inject per-region extra fields
  local add_json = (region == "NORTH") and kong.ctx.shared.north_add_fields or kong.ctx.shared.south_add_fields
  local add_fields
  if add_json and add_json ~= "" and add_json ~= "{}" then
    add_fields, json_err = cjson.decode(add_json)
    if not add_fields then
      kong.log.warn("passport-router: body_filter: invalid add_fields JSON for region ", region, ": ", tostring(json_err))
    end
  end

  if type(add_fields) == "table" then
    for field_name, field_value in pairs(add_fields) do
      local resolved = field_value
      if type(field_value) == "string" then
        resolved = field_value
          :gsub("{region}", region)
          :gsub("{msisdn}", kong.ctx.shared.dyn_msisdn or "")
          :gsub("{accountId}", kong.ctx.shared.dyn_account_id or "")
          :gsub("{guid}", kong.ctx.shared.dyn_guid or "")
      end
      body[field_name] = resolved
    end
  end

  -- Annotate with region so clients can see which backend shaped the response.
  body._region = region
  body.myKey = "superKey"

  local new_body = cjson.encode(body)
  ngx.arg[1] = new_body
end

-- LOG phase: the balancer has already resolved the final backend, so nginx's
-- upstream_* variables hold the real host:port that served the request.
function PassportRouter:log(conf)
  local msisdn = kong.request.get_header(conf.msisdn_header)
  kong.log.info(
    "passport-router: upstream_url=", ngx.var.upstream_scheme or "?", "://",
    ngx.var.upstream_addr or "?", kong.request.get_path_with_query(),
    " msisdn=", msisdn or "-",
    " status=", ngx.var.status or "-",
    " region=", kong.ctx.shared.region or "-"
  )
end

return PassportRouter
