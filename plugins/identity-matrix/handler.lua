-- kong/plugins/identity-matrix/handler.lua
local redis = require "resty.redis"
local cjson = require "cjson.safe"

local IdentityMatrix = {
  VERSION = "2.0.0",
  PRIORITY = 950,
}

local function normalize_str(val)
  if val == nil then return nil end
  local s = tostring(val)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s
end

local function csv(val)
  if val == nil then return "" end
  if type(val) == "table" then
    return table.concat(val, ",")
  end
  return tostring(val)
end

local function path_matches(req_path, list)
  if not list or type(list) ~= "table" then return false end
  local norm_req = string.lower(req_path or "")
  for _, p in ipairs(list) do
    if type(p) == "string" and string.lower(p) == norm_req then
      return true
    end
  end
  return false
end

local function get_or_parse_body()
  if kong.ctx.shared.parsed_body ~= nil then
    return kong.ctx.shared.parsed_body
  end

  ngx.req.read_body()
  local raw_body = ngx.req.get_body_data()
  if not raw_body then
    local file_name = ngx.req.get_body_file()
    if file_name then
      local f = io.open(file_name, "rb")
      if f then
        raw_body = f:read("*all")
        f:close()
      end
    end
  end

  local parsed = nil
  if raw_body and raw_body ~= "" then
    parsed = cjson.decode(raw_body)
  end

  if not parsed or type(parsed) ~= "table" then
    parsed = kong.request.get_body()
  end

  kong.ctx.shared.parsed_body = (type(parsed) == "table") and parsed or {}
  return kong.ctx.shared.parsed_body
end

local function extract_msisdn(conf)
  -- 1. Try configured header (e.g. X-MSISDN)
  local msisdn = kong.request.get_header(conf.msisdn_header)
  if msisdn and msisdn ~= "" then
    return normalize_str(msisdn)
  end

  -- 2. Try query parameter
  msisdn = kong.request.get_query_arg("msisdn") or kong.request.get_query_arg("username")
  if msisdn and msisdn ~= "" then
    return normalize_str(msisdn)
  end

  -- 3. Try request body
  local body = get_or_parse_body()
  if body and type(body) == "table" then
    msisdn = body[conf.msisdn_body_field] or body.username or body.msisdn or body.phone
    if msisdn and msisdn ~= "" then
      return normalize_str(msisdn)
    end
  end

  return nil
end

local function extract_device_id(conf)
  local dev = kong.request.get_header(conf.device_id_header) or kong.request.get_header("X-Device-Id")
  if dev and dev ~= "" then
    return normalize_str(dev)
  end

  local body = get_or_parse_body()
  if body and type(body) == "table" then
    dev = body.deviceId or body.device_id
    if dev and dev ~= "" then
      return normalize_str(dev)
    end
  end

  return nil
end

local function extract_target_region(conf)
  -- 1. Try header (e.g. X-Target-Region or X-Region)
  local region = kong.request.get_header(conf.region_header) or kong.request.get_header("X-Region")
  if region and region ~= "" then
    return string.upper(normalize_str(region))
  end

  -- 2. Try query parameter
  region = kong.request.get_query_arg("region") or kong.request.get_query_arg("targetRegion")
  if region and region ~= "" then
    return string.upper(normalize_str(region))
  end

  -- 3. Try request body
  local body = get_or_parse_body()
  if body and type(body) == "table" then
    region = body[conf.region_body_field] or body.region or body.targetRegion
    if region and region ~= "" then
      return string.upper(normalize_str(region))
    end
  end

  return nil
end

local function connect_redis(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    kong.log.err("identity-matrix: redis connect failed: ", err)
    return nil, err
  end
  return red, nil
end

local function fetch_passport_state(conf, red, msisdn, device_id)
  local key = conf.passport_prefix .. msisdn
  local res, get_err = red:get(key)
  if get_err then
    kong.log.err("identity-matrix: redis GET failed for key ", key, ": ", get_err)
    return false, nil, "Redis lookup error"
  end

  local isNorthExisted = false
  local isSouthExisted = false
  local northProfile = nil
  local southProfile = nil
  local passport = nil

  if res and res ~= ngx.null and res ~= "" then
    local decoded, json_err = cjson.decode(res)
    if decoded and type(decoded) == "table" then
      passport = decoded

      if passport.profiles and type(passport.profiles) == "table" then
        for _, p in ipairs(passport.profiles) do
          if type(p) == "table" then
            local r = string.upper(p.route or p.region or "")
            local status = p.status and string.upper(normalize_str(p.status)) or "ACTIVE"
            local pin_init = p.pinInitialized
            if pin_init == nil then
              pin_init = (status ~= "NOT_INITIALIZED")
            end

            local prof = {
              route = r,
              accountId = p.accountId,
              persona = p.persona,
              personaId = p.personaId or p.personaID,
              status = status,
              pinInitialized = pin_init,
              tier = p.tier or "TIER0",
              kycStatus = p.kycStatus or "PENDING",
              lastUpdated = p.lastUpdated,
            }

            if r == "NORTH" then
              isNorthExisted = true
              northProfile = prof
            elseif r == "SOUTH" then
              isSouthExisted = true
              southProfile = prof
            end
          end
        end
      end
    else
      kong.log.warn("identity-matrix: invalid passport JSON for ", key, ": ", json_err)
    end
  end

  -- Device-specific preference lookup (AC-11)
  local device_route = nil
  if device_id and passport and passport.deviceDefaults and type(passport.deviceDefaults) == "table" then
    for _, dd in ipairs(passport.deviceDefaults) do
      if dd.deviceId and string.lower(dd.deviceId) == string.lower(device_id) then
        if dd.route and dd.route ~= "" then
          device_route = string.upper(normalize_str(dd.route))
          break
        end
      end
    end
  end

  local default_route = device_route or (passport and passport.defaultRoute and string.upper(normalize_str(passport.defaultRoute))) or nil

  return true, {
    passport = passport,
    isNorthExisted = isNorthExisted,
    isSouthExisted = isSouthExisted,
    northProfile = northProfile,
    southProfile = southProfile,
    defaultRoute = default_route,
    deviceRoute = device_route,
  }, nil
end

function IdentityMatrix:access(conf)
  local req_path = kong.request.get_path()
  local is_login = path_matches(req_path, conf.login_paths)
  local is_register = path_matches(req_path, conf.register_paths)
  local is_precheck = path_matches(req_path, conf.precheck_paths)

  if not is_login and not is_register and not is_precheck then
    return
  end

  -- Extract MSISDN
  local msisdn = extract_msisdn(conf)
  if not msisdn then
    return kong.response.exit(400, {
      status = false,
      errorCode = "REG-ID-001",
      message = "MSISDN is required (via " .. conf.msisdn_header .. " header or JSON body)"
    })
  end

  local device_id = extract_device_id(conf)

  local red, conn_err = connect_redis(conf)
  if not red then
    return kong.response.exit(503, {
      status = false,
      errorCode = "SW_008",
      message = "Identity validation service unavailable: " .. tostring(conn_err)
    })
  end

  local lookup_ok, state, lookup_err = fetch_passport_state(conf, red, msisdn, device_id)
  if not lookup_ok then
    red:set_keepalive()
    return kong.response.exit(503, {
      status = false,
      errorCode = "SW_008",
      message = "Identity validation service unavailable: " .. tostring(lookup_err)
    })
  end

  local isNorthExisted = state.isNorthExisted
  local isSouthExisted = state.isSouthExisted
  local defaultRoute = state.defaultRoute
  local northProfile = state.northProfile
  local southProfile = state.southProfile
  local passport = state.passport

  kong.ctx.plugin = {
    msisdn = msisdn,
    deviceId = device_id,
    path = req_path,
    startTime = ngx.now(),
  }

  ---------------------------------------------------------------------------
  -- 1. PRECHECK FLOW (AC-01, AC-02, AC-03, AC-12)
  ---------------------------------------------------------------------------
  if is_precheck then
    red:set_keepalive()

    -- Check Suspended or AML-blocked scenarios (Scenario 6)
    local north_restricted = northProfile and (northProfile.status == "SUSPENDED" or northProfile.status == "AML_BLOCKED" or northProfile.status == "BLOCKED")
    local south_restricted = southProfile and (southProfile.status == "SUSPENDED" or southProfile.status == "AML_BLOCKED" or southProfile.status == "BLOCKED")

    if (isNorthExisted and north_restricted) and (not isSouthExisted or south_restricted) then
      return kong.response.exit(403, {
        status = false,
        action = "BLOCKED",
        errorCode = "REG-ID-013",
        message = "We are unable to process your request at this time. Please contact customer support."
      })
    end
    if (isSouthExisted and south_restricted) and (not isNorthExisted or north_restricted) then
      return kong.response.exit(403, {
        status = false,
        action = "BLOCKED",
        errorCode = "REG-ID-013",
        message = "We are unable to process your request at this time. Please contact customer support."
      })
    end

    local login_action
    local login_target
    local login_validation = nil

    if not isNorthExisted and not isSouthExisted then
      login_action = "GO_TO_SIGN_UP"
      login_validation = "Account does not existed on both"
    elseif isNorthExisted and not isSouthExisted then
      if northProfile.status == "NOT_INITIALIZED" or (not northProfile.pinInitialized) then
        login_action = "FIRST_TIME_PIN_SETUP"
        login_validation = "PIN not initialized."
      else
        login_action = "LOGIN_NORTH"
      end
      login_target = "NORTH"
    elseif not isNorthExisted and isSouthExisted then
      if southProfile.status == "NOT_INITIALIZED" or (not southProfile.pinInitialized) then
        login_action = "FIRST_TIME_PIN_SETUP"
        login_validation = "PIN not initialized."
      else
        login_action = "LOGIN_SOUTH"
      end
      login_target = "SOUTH"
    else -- Both exist
      local active_target = defaultRoute or "NORTH"
      local active_prof = (active_target == "NORTH") and northProfile or southProfile
      if active_prof.status == "NOT_INITIALIZED" or (not active_prof.pinInitialized) then
        login_action = "FIRST_TIME_PIN_SETUP"
        login_validation = "PIN not initialized."
      else
        login_action = "LOGIN_DEFAULT"
      end
      login_target = active_target
    end

    local reg_action
    local reg_allowed = {}
    local reg_validation = "N/A"

    -- Terminated account handling (Scenario 7)
    local north_terminated = northProfile and (northProfile.status == "TERMINATED")
    local south_terminated = southProfile and (southProfile.status == "TERMINATED")

    if not isNorthExisted and not isSouthExisted then
      reg_action = "REGISTER_BASED_ON_INPUT_REGION"
      reg_allowed = { "NORTH", "SOUTH" }
      reg_validation = "N/A"
    elseif isNorthExisted and not isSouthExisted then
      reg_action = "REGISTER_ONLY_ON_SOUTH"
      reg_allowed = { "SOUTH" }
      reg_validation = "Account already existed in North"
    elseif not isNorthExisted and isSouthExisted then
      reg_action = "REGISTER_ONLY_ON_NORTH"
      reg_allowed = { "NORTH" }
      reg_validation = "Account already existed in South"
    elseif north_terminated and not south_terminated then
      reg_action = "REPLACEMENT_ON_NORTH"
      reg_allowed = { "NORTH" }
      reg_validation = "Replacement allowed for terminated account"
    elseif south_terminated and not north_terminated then
      reg_action = "REPLACEMENT_ON_SOUTH"
      reg_allowed = { "SOUTH" }
      reg_validation = "Replacement allowed for terminated account"
    else -- Both exist and active
      reg_action = "GO_TO_LOGIN_SCREEN"
      reg_allowed = {}
      reg_validation = "You already have the maximum number of accounts allowed for this mobile number."
    end

    return kong.response.exit(200, {
      status = true,
      msisdn = msisdn,
      isNorthExisted = isNorthExisted,
      isSouthExisted = isSouthExisted,
      defaultRoute = defaultRoute,
      deviceRoute = state.deviceRoute,
      login = {
        action = login_action,
        canLogin = (isNorthExisted or isSouthExisted),
        targetRegion = login_target,
        validation = login_validation,
      },
      registration = {
        action = reg_action,
        canRegister = not (isNorthExisted and isSouthExisted) or north_terminated or south_terminated,
        allowedRegions = reg_allowed,
        validation = reg_validation,
      }
    })
  end

  ---------------------------------------------------------------------------
  -- 2. LOGIN FLOW (AC-04, AC-05, AC-11, Scenarios 4, 5, 6)
  ---------------------------------------------------------------------------
  if is_login then
    red:set_keepalive()

    -- Rule 1: No accounts -> Go to Sign Up
    if not isNorthExisted and not isSouthExisted then
      return kong.response.exit(404, {
        status = false,
        action = "GO_TO_SIGN_UP",
        message = "Account does not existed on both",
        isNorthExisted = false,
        isSouthExisted = false
      })
    end

    local target_upstream
    local target_route
    local selected_profile

    -- Rule 2: Only North exists
    if isNorthExisted and not isSouthExisted then
      target_route = "NORTH"
      selected_profile = northProfile

    -- Rule 3: Only South exists
    elseif not isNorthExisted and isSouthExisted then
      target_route = "SOUTH"
      selected_profile = southProfile

    -- Rule 4: Both exist -> Use device preferred defaultRoute, or global defaultRoute
    else
      target_route = defaultRoute or "NORTH"
      selected_profile = (target_route == "SOUTH") and southProfile or northProfile

      -- Scenario 5: Default wallet is Suspended, other wallet is Active
      if selected_profile.status == "SUSPENDED" or selected_profile.status == "AML_BLOCKED" or selected_profile.status == "BLOCKED" then
        local alternative_route = (target_route == "NORTH") and "SOUTH" or "NORTH"
        local alternative_prof = (alternative_route == "NORTH") and northProfile or southProfile
        if alternative_prof and alternative_prof.status == "ACTIVE" then
          target_route = alternative_route
          selected_profile = alternative_prof
        end
      end
    end

    -- Validate Account Status (AC-04, §2.3, §2.4)
    if selected_profile.status == "AML_BLOCKED" or selected_profile.status == "SUSPENDED" then
      return kong.response.exit(403, {
        status = false,
        action = "BLOCKED",
        errorCode = "REG-ID-013",
        message = "We are unable to process your request at this time. Please contact customer support."
      })
    end

    if selected_profile.status == "BLOCKED" or selected_profile.status == "TERMINATED" then
      return kong.response.exit(403, {
        status = false,
        action = "INACCESSIBLE",
        errorCode = "SW_003",
        message = "This account is not accessible."
      })
    end

    -- PIN Not Initialized (AC-06, Scenario 4)
    if selected_profile.status == "NOT_INITIALIZED" or (not selected_profile.pinInitialized) then
      return kong.response.exit(400, {
        status = false,
        action = "FIRST_TIME_PIN_SETUP",
        errorCode = "SW_005",
        message = "PIN not initialized.",
        targetRegion = target_route,
      })
    end

    target_upstream = (target_route == "NORTH") and conf.north_upstream or conf.south_upstream

    -- Override upstream
    local set_ok, set_err = kong.service.set_upstream(target_upstream)
    if not set_ok then
      kong.log.err("identity-matrix: set_upstream failed for ", target_upstream, ": ", set_err)
      return kong.response.exit(503, {
        status = false,
        errorCode = "SW_008",
        message = "Backend routing unavailable"
      })
    end

    -- Forward trusted headers with safe CSV string handling
    if conf.send_trusted_headers then
      kong.service.request.set_header("X-Region", target_route)
      if selected_profile then
        kong.service.request.set_header("X-Account-Id", tostring(selected_profile.accountId or ""))
        kong.service.request.set_header("X-Persona", csv(selected_profile.persona))
        kong.service.request.set_header("X-Persona-Id", csv(selected_profile.personaId or selected_profile.personaID))
      end
      if passport and passport.guid then
        kong.service.request.set_header("X-Passport-Guid", tostring(passport.guid))
      end
      if device_id then
        kong.service.request.set_header("X-Device-Id", device_id)
      end
    end

    kong.ctx.plugin.action = "LOGIN"
    kong.ctx.plugin.targetRegion = target_route
    return
  end

  ---------------------------------------------------------------------------
  -- 3. REGISTRATION FLOW (AC-12, AC-19, AC-20, Scenarios 8, 9)
  ---------------------------------------------------------------------------
  if is_register then
    -- AML or Suspended customer cannot register new accounts (AC-12, §2.4, Scenario 6)
    if (northProfile and (northProfile.status == "SUSPENDED" or northProfile.status == "AML_BLOCKED")) or
       (southProfile and (southProfile.status == "SUSPENDED" or southProfile.status == "AML_BLOCKED")) then
      red:set_keepalive()
      return kong.response.exit(403, {
        status = false,
        errorCode = "REG-ID-013",
        message = "We are unable to process your request at this time. Please contact customer support."
      })
    end

    local north_term = northProfile and (northProfile.status == "TERMINATED")
    local south_term = southProfile and (southProfile.status == "TERMINATED")

    -- Rule: Maximum 2 accounts per MSISDN (AC-19, Scenario 8)
    if isNorthExisted and isSouthExisted and not north_term and not south_term then
      red:set_keepalive()
      return kong.response.exit(409, {
        status = false,
        errorCode = "REG-ID-012",
        action = "GO_TO_LOGIN_SCREEN",
        message = "You already have the maximum number of accounts allowed for this mobile number."
      })
    end

    local input_region = extract_target_region(conf)

    -- Rule: Opposite region enforcement (AC-12)
    if isNorthExisted and not isSouthExisted and not north_term then
      if input_region == "NORTH" then
        red:set_keepalive()
        return kong.response.exit(400, {
          status = false,
          errorCode = "REG-ID-012",
          action = "REGISTER_ONLY_ON_SOUTH",
          message = "You already have an account in this region."
        })
      end
      input_region = "SOUTH"
    elseif not isNorthExisted and isSouthExisted and not south_term then
      if input_region == "SOUTH" then
        red:set_keepalive()
        return kong.response.exit(400, {
          status = false,
          errorCode = "REG-ID-012",
          action = "REGISTER_ONLY_ON_NORTH",
          message = "You already have an account in this region."
        })
      end
      input_region = "NORTH"
    end

    -- First account registration: region is taken from the X-Region header or
    -- the request body (extract_target_region above). It is no longer mandatory
    -- here — when absent the request simply proceeds with default routing.

    -- AC-20: Idempotency lock to prevent duplicate registration
    local lock_key = "lock:reg:" .. msisdn
    local lock_res, _ = red:set(lock_key, "1", "EX", conf.idempotency_ttl_seconds, "NX")
    red:set_keepalive()

    if not lock_res or lock_res == ngx.null then
      return kong.response.exit(429, {
        status = false,
        errorCode = "PIN-017",
        message = "Your request is already being processed. Please wait."
      })
    end

    -- Route to the region backend only when a region was provided (header/body).
    -- When no region came in with the request (first registration), skip the
    -- override so the request uses the service's configured default upstream.
    if input_region then
      local target_upstream = (input_region == "NORTH") and conf.north_upstream or conf.south_upstream
      local set_ok, set_err = kong.service.set_upstream(target_upstream)
      if not set_ok then
        kong.log.err("identity-matrix: set_upstream failed for ", target_upstream, ": ", set_err)
        return kong.response.exit(503, {
          status = false,
          errorCode = "SW_008",
          message = "Backend routing unavailable"
        })
      end
    end

    if conf.send_trusted_headers then
      if input_region then
        kong.service.request.set_header("X-Region", input_region)
      end
      if passport and passport.guid then
        kong.service.request.set_header("X-Passport-Guid", tostring(passport.guid))
      end
      if device_id then
        kong.service.request.set_header("X-Device-Id", device_id)
      end
    end

    kong.ctx.plugin.action = "REGISTER"
    kong.ctx.plugin.targetRegion = input_region
    return
  end
end

function IdentityMatrix:header_filter(conf)
  if conf.strip_internal_names then
    ngx.header["Content-Length"] = nil
  end
end

function IdentityMatrix:body_filter(conf)
  if not conf.strip_internal_names then
    return
  end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]

  local buffer = kong.ctx.shared.id_matrix_body or ""
  if chunk and chunk ~= "" then
    buffer = buffer .. chunk
  end
  kong.ctx.shared.id_matrix_body = buffer

  if not eof then
    ngx.arg[1] = nil
    return
  end

  -- Scrub internal names (Telepin, YottaGet) as mandated by §2.1
  local sanitized = buffer:gsub("[Tt]elepin", "Core Banking"):gsub("[Yy]otta[Gg]et", "Core Banking")
  ngx.arg[1] = sanitized
end

function IdentityMatrix:log(conf)
  if not conf.audit_logging_enabled then
    return
  end

  local ctx = kong.ctx.plugin
  if not ctx then
    return
  end

  local status = kong.response.get_status()
  local latency = ngx.now() - (ctx.startTime or ngx.now())

  local event_name = "identity_access"
  if ctx.action == "LOGIN" then
    event_name = (status < 400) and "login_completed" or "login_failed"
  elseif ctx.action == "REGISTER" then
    event_name = (status < 400) and "account_created" or "account_creation_validation_failed"
  end

  local audit_entry = {
    event = event_name,
    msisdn = ctx.msisdn,
    deviceId = ctx.deviceId,
    path = ctx.path,
    targetRegion = ctx.targetRegion,
    httpStatus = status,
    latencyMs = math.floor(latency * 1000),
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }

  kong.log.info("identity-matrix-audit: ", cjson.encode(audit_entry))
end

return IdentityMatrix
