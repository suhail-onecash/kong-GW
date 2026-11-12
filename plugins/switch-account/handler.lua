-- kong/plugins/switch-account/handler.lua
local redis = require "resty.redis"
local cjson = require "cjson.safe"

local SwitchAccount = {
  VERSION = "1.0.0",
  PRIORITY = 960, -- Runs before identity-matrix (950) and passport-router (900)
}

local function normalize_str(val)
  if val == nil then return nil end
  local s = tostring(val)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s
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
  -- 1. Configured header (e.g. X-MSISDN)
  local msisdn = kong.request.get_header(conf.msisdn_header)
  if msisdn and msisdn ~= "" then
    return normalize_str(msisdn)
  end

  -- 2. Query parameter
  msisdn = kong.request.get_query_arg("msisdn") or kong.request.get_query_arg("username")
  if msisdn and msisdn ~= "" then
    return normalize_str(msisdn)
  end

  -- 3. Request body
  local body = get_or_parse_body()
  if body and type(body) == "table" then
    msisdn = body.msisdn or body.username or body.phone
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
  local region = kong.request.get_header(conf.region_header) or kong.request.get_header("X-Region")
  if region and region ~= "" then
    return string.upper(normalize_str(region))
  end

  region = kong.request.get_query_arg("region") or kong.request.get_query_arg("targetRegion")
  if region and region ~= "" then
    return string.upper(normalize_str(region))
  end

  local body = get_or_parse_body()
  if body and type(body) == "table" then
    region = body.targetRegion or body.region
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
    kong.log.err("switch-account: redis connect failed: ", err)
    return nil, err
  end
  return red, nil
end

local function close_redis(red)
  if not red then return end
  local ok, err = red:set_keepalive()
  if not ok then
    kong.log.warn("switch-account: redis keepalive failed: ", err)
  end
end

local function fetch_passport_state(conf, red, msisdn, device_id)
  local key = conf.passport_prefix .. msisdn
  local res, err = red:get(key)
  if err then
    kong.log.err("switch-account: redis get failed for ", key, ": ", err)
    return false, nil, "Redis lookup error"
  end

  if not res or res == ngx.null or res == "" then
    return true, nil, nil
  end

  local passport, json_err = cjson.decode(res)
  if not passport or type(passport) ~= "table" then
    kong.log.warn("switch-account: invalid passport JSON for ", key, ": ", json_err)
    return false, nil, "Invalid passport format"
  end

  local north_profile = nil
  local south_profile = nil
  local profiles_list = {}

  if passport.profiles and type(passport.profiles) == "table" then
    for _, p in ipairs(passport.profiles) do
      if type(p) == "table" then
        local r = string.upper(p.route or p.region or "")
        -- Normalize status and pinInitialized
        local status = p.status and string.upper(normalize_str(p.status)) or "ACTIVE"
        local pin_init = p.pinInitialized
        if pin_init == nil then
          pin_init = (status ~= "NOT_INITIALIZED")
        end

        local prof_data = {
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
          north_profile = prof_data
        elseif r == "SOUTH" then
          south_profile = prof_data
        end
        table.insert(profiles_list, prof_data)
      end
    end
  end

  -- Determine device-preferred route if deviceDefaults is configured (AC-11)
  local device_route = nil
  if device_id and passport.deviceDefaults and type(passport.deviceDefaults) == "table" then
    for _, dd in ipairs(passport.deviceDefaults) do
      if dd.deviceId and string.lower(dd.deviceId) == string.lower(device_id) then
        if dd.route and dd.route ~= "" then
          device_route = string.upper(normalize_str(dd.route))
          break
        end
      end
    end
  end

  local default_route = device_route or (passport.defaultRoute and string.upper(normalize_str(passport.defaultRoute))) or "NORTH"

  return true, {
    raw_passport = passport,
    guid = passport.guid,
    msisdn = msisdn,
    defaultRoute = default_route,
    deviceRoute = device_route,
    northProfile = north_profile,
    southProfile = south_profile,
    profiles = profiles_list,
    isNorthExisted = (north_profile ~= nil),
    isSouthExisted = (south_profile ~= nil),
  }, nil
end

function SwitchAccount:access(conf)
  local req_path = kong.request.get_path()
  local is_decision = path_matches(req_path, conf.decision_paths)
  local is_switch = path_matches(req_path, conf.switch_paths)
  local is_set_default = path_matches(req_path, conf.set_default_paths)
  local is_create = path_matches(req_path, conf.create_paths)

  if not is_decision and not is_switch and not is_set_default and not is_create then
    return
  end

  local msisdn = extract_msisdn(conf)
  if not msisdn then
    return kong.response.exit(400, {
      status = false,
      errorCode = "REG-ID-001",
      message = "MSISDN header is required",
    })
  end

  local device_id = extract_device_id(conf)

  local red, red_err = connect_redis(conf)
  if not red then
    return kong.response.exit(503, {
      status = false,
      errorCode = "SW_008",
      message = "System unavailable",
    })
  end

  local ok, state, state_err = fetch_passport_state(conf, red, msisdn, device_id)
  if not ok then
    close_redis(red)
    return kong.response.exit(503, {
      status = false,
      errorCode = "SW_008",
      message = "Identity validation service unavailable: " .. tostring(state_err),
    })
  end

  -- Context for logging & filters
  kong.ctx.plugin = {
    msisdn = msisdn,
    deviceId = device_id,
    path = req_path,
    startTime = ngx.now(),
  }

  ---------------------------------------------------------------------------
  -- 1. JOURNEY DECISION ENDPOINT (AC-01, AC-02, AC-03, AC-04, AC-12)
  ---------------------------------------------------------------------------
  if is_decision then
    close_redis(red)

    if not state or (#state.profiles == 0) then
      -- Customer does not exist in any region yet
      return kong.response.exit(404, {
        status = false,
        action = "GO_TO_SIGN_UP",
        message = "Account does not existed on both",
      })
    end

    local north = state.northProfile
    local south = state.southProfile
    local active_route = state.defaultRoute

    -- Check Suspended or AML-blocked scenarios (AC-02, §2.4, Scenarios 5, 6)
    local north_blocked = north and (north.status == "SUSPENDED" or north.status == "AML_BLOCKED" or north.status == "BLOCKED")
    local south_blocked = south and (south.status == "SUSPENDED" or south.status == "AML_BLOCKED" or south.status == "BLOCKED")

    -- Scenario 6: If all existing wallets are AML-blocked or Suspended
    if (north and north_blocked) and (not south or south_blocked) then
      return kong.response.exit(403, {
        status = false,
        action = "BLOCKED",
        errorCode = "SW_003",
        message = "Your account is currently unavailable. Please contact customer support.",
      })
    end
    if (south and south_blocked) and (not north or north_blocked) then
      return kong.response.exit(403, {
        status = false,
        action = "BLOCKED",
        errorCode = "SW_003",
        message = "Your account is currently unavailable. Please contact customer support.",
      })
    end

    -- Scenario 5: Default wallet is Suspended, but other wallet is Active
    if north and south then
      local active_prof = (active_route == "NORTH") and north or south
      local target_prof = (active_route == "NORTH") and south or north
      local target_route = (active_route == "NORTH") and "SOUTH" or "NORTH"

      -- If current active wallet is suspended/blocked, auto-redirect focus to eligible wallet
      if active_prof.status == "SUSPENDED" or active_prof.status == "AML_BLOCKED" or active_prof.status == "BLOCKED" then
        if target_prof.status == "ACTIVE" then
          active_prof = target_prof
          target_prof = (active_route == "NORTH") and north or south
          active_route = target_route
          target_route = (active_route == "NORTH") and "SOUTH" or "NORTH"
        end
      end

      -- Scenario 7: One of two wallets is Terminated
      local replacement_available = false
      local replacement_region = nil
      if north.status == "TERMINATED" then
        replacement_available = true
        replacement_region = "NORTH"
      elseif south.status == "TERMINATED" then
        replacement_available = true
        replacement_region = "SOUTH"
      end

      -- Scenario 4 & AC-06: Target wallet PIN is Not Initialized
      local target_not_initialized = (target_prof.status == "NOT_INITIALIZED") or (not target_prof.pinInitialized)

      local decision_action = "SWITCH"
      local decision_code = nil
      local decision_msg = nil

      if target_not_initialized then
        decision_action = "FIRST_TIME_PIN_SETUP"
        decision_code = "SW_005"
        decision_msg = "PIN not initialized."
      elseif replacement_available then
        decision_action = "SWITCH_AND_REPLACEMENT"
      end

      return kong.response.exit(200, {
        status = true,
        action = decision_action,
        errorCode = decision_code,
        message = decision_msg,
        activeWallet = {
          region = active_route,
          accountId = active_prof.accountId,
          status = active_prof.status,
          pinInitialized = active_prof.pinInitialized,
          tier = active_prof.tier,
        },
        targetWallet = {
          region = target_route,
          accountId = target_prof.accountId,
          status = target_prof.status,
          pinInitialized = target_prof.pinInitialized,
          tier = target_prof.tier,
          isAccessible = (target_prof.status == "ACTIVE" or target_prof.status == "NOT_INITIALIZED"),
        },
        replacement = {
          available = replacement_available,
          region = replacement_region,
        },
        devicePreference = {
          deviceId = device_id,
          preferredRoute = state.deviceRoute or state.defaultRoute,
        },
        canSwitch = (target_prof.status == "ACTIVE" or target_not_initialized),
        canCreate = replacement_available, -- 3rd wallet prohibited (Scenario 8)
      })
    end

    -- Only ONE eligible wallet exists (AC-02, Scenario 1 & 2)
    local existing_prof = north or south
    local existing_region = north and "NORTH" or "SOUTH"
    local opposite_region = (existing_region == "NORTH") and "SOUTH" or "NORTH"

    -- Tier 0 or downgraded can create second wallet opposite
    return kong.response.exit(200, {
      status = true,
      action = "CREATE",
      canSwitch = false,
      canCreate = true,
      existingWallet = {
        region = existing_region,
        accountId = existing_prof.accountId,
        status = existing_prof.status,
        pinInitialized = existing_prof.pinInitialized,
        tier = existing_prof.tier,
      },
      targetRegion = opposite_region,
      devicePreference = {
        deviceId = device_id,
        preferredRoute = existing_region,
      },
    })
  end

  ---------------------------------------------------------------------------
  -- 2. SWITCH AUTHENTICATION PATH (AC-04, AC-05, AC-10, AC-22)
  ---------------------------------------------------------------------------
  if is_switch then
    close_redis(red)

    local target_region = extract_target_region(conf)
    if not target_region or (target_region ~= "NORTH" and target_region ~= "SOUTH") then
      return kong.response.exit(400, {
        status = false,
        errorCode = "SW_008",
        message = "Target region (NORTH or SOUTH) is required",
      })
    end

    if not state then
      return kong.response.exit(404, {
        status = false,
        errorCode = "SW_008",
        message = "Passport not found",
      })
    end

    local target_prof = (target_region == "NORTH") and state.northProfile or state.southProfile
    if not target_prof then
      return kong.response.exit(404, {
        status = false,
        errorCode = "SW_008",
        message = "Target wallet not found for region " .. target_region,
      })
    end

    -- AC-04: Validate Target Account Status
    if target_prof.status == "BLOCKED"
        or target_prof.status == "SUSPENDED"
        or target_prof.status == "AML_BLOCKED"
        or target_prof.status == "TERMINATED" then
      return kong.response.exit(403, {
        status = false,
        errorCode = "SW_003",
        message = "This account is not accessible.",
      })
    end

    -- AC-06: Target wallet PIN must be initialized before normal switch auth
    if target_prof.status == "NOT_INITIALIZED" or (not target_prof.pinInitialized) then
      return kong.response.exit(400, {
        status = false,
        errorCode = "SW_005",
        message = "PIN not initialized.",
        action = "FIRST_TIME_PIN_SETUP",
        targetRegion = target_region,
      })
    end

    -- Dynamic Upstream Routing
    local upstream = (target_region == "NORTH") and conf.north_upstream or conf.south_upstream
    local set_ok, set_err = kong.service.set_upstream(upstream)
    if not set_ok then
      kong.log.err("switch-account: set_upstream failed for ", upstream, ": ", set_err)
      return kong.response.exit(503, {
        status = false,
        errorCode = "SW_008",
        message = "System unavailable",
      })
    end

    -- Stamp trusted context headers
    kong.service.request.set_header("X-Region", target_region)
    kong.service.request.set_header("X-Account-Id", tostring(target_prof.accountId or ""))
    kong.service.request.set_header("X-Persona", tostring(target_prof.persona and target_prof.persona[1] or ""))
    kong.service.request.set_header("X-Persona-Id", tostring(target_prof.personaId and target_prof.personaId[1] or ""))
    if state.guid then
      kong.service.request.set_header("X-Passport-Guid", tostring(state.guid))
    end
    if device_id then
      kong.service.request.set_header("X-Device-Id", device_id)
    end

    kong.ctx.plugin.targetRegion = target_region
    kong.ctx.plugin.targetAccountId = target_prof.accountId
    kong.ctx.plugin.action = "SWITCH"
    return
  end

  ---------------------------------------------------------------------------
  -- 3. PER-DEVICE DEFAULT WALLET ENDPOINT (AC-11, Scenario 13)
  ---------------------------------------------------------------------------
  if is_set_default then
    if not device_id or device_id == "" then
      close_redis(red)
      return kong.response.exit(400, {
        status = false,
        errorCode = "SW_007",
        message = "Device-Id header or body field is required",
      })
    end

    local target_region = extract_target_region(conf)
    if not target_region or (target_region ~= "NORTH" and target_region ~= "SOUTH") then
      close_redis(red)
      return kong.response.exit(400, {
        status = false,
        errorCode = "SW_008",
        message = "Valid target route (NORTH or SOUTH) is required",
      })
    end

    if not state or not state.raw_passport then
      close_redis(red)
      return kong.response.exit(404, {
        status = false,
        errorCode = "SW_008",
        message = "Passport not found",
      })
    end

    local pass = state.raw_passport
    local now = os.date("%Y-%m-%d %H:%M:%S")

    if not pass.deviceDefaults or type(pass.deviceDefaults) ~= "table" then
      pass.deviceDefaults = {}
    end

    local found = false
    for _, dd in ipairs(pass.deviceDefaults) do
      if dd.deviceId and string.lower(dd.deviceId) == string.lower(device_id) then
        dd.route = target_region
        dd.lastUpdated = now
        found = true
        break
      end
    end

    if not found then
      table.insert(pass.deviceDefaults, {
        deviceId = device_id,
        route = target_region,
        lastUpdated = now,
      })
    end

    pass.lastUpdated = now
    local key = conf.passport_prefix .. msisdn
    local save_ok, save_err = red:set(key, cjson.encode(pass))
    close_redis(red)

    if not save_ok then
      kong.log.err("switch-account: failed to save deviceDefaults for ", msisdn, ": ", save_err)
      return kong.response.exit(500, {
        status = false,
        errorCode = "SW_008",
        message = "Unable to update default preference",
      })
    end

    kong.ctx.plugin.action = "SET_DEVICE_DEFAULT"
    kong.ctx.plugin.targetRegion = target_region
    return kong.response.exit(200, {
      status = true,
      message = "Default wallet updated for this device",
      deviceId = device_id,
      route = target_region,
    })
  end

  ---------------------------------------------------------------------------
  -- 4. CREATE SECOND ACCOUNT GUARDS (AC-12, AC-19, AC-20, Scenarios 1, 2, 8)
  ---------------------------------------------------------------------------
  if is_create then
    -- Rule: Maximum 2 accounts per MSISDN (AC-19, Scenario 8)
    if state and state.isNorthExisted and state.isSouthExisted then
      close_redis(red)
      return kong.response.exit(409, {
        status = false,
        errorCode = "REG-ID-012",
        message = "You already have the maximum number of accounts allowed for this mobile number.",
      })
    end

    -- Rule: AML or Suspended customer cannot create another wallet (AC-12, §2.4, Scenario 6)
    if state and ((state.northProfile and (state.northProfile.status == "SUSPENDED" or state.northProfile.status == "AML_BLOCKED")) or
                 (state.southProfile and (state.southProfile.status == "SUSPENDED" or state.southProfile.status == "AML_BLOCKED"))) then
      close_redis(red)
      return kong.response.exit(403, {
        status = false,
        errorCode = "REG-ID-013",
        message = "We are unable to process your request at this time. Please contact customer support.",
      })
    end

    local input_region = extract_target_region(conf)

    -- Rule: Must create in opposite region (AC-12, AC-19)
    if state then
      if state.isNorthExisted and not state.isSouthExisted then
        if input_region == "NORTH" then
          close_redis(red)
          return kong.response.exit(400, {
            status = false,
            errorCode = "REG-ID-012",
            message = "You already have an account in this region.",
          })
        end
        input_region = "SOUTH"
      elseif not state.isNorthExisted and state.isSouthExisted then
        if input_region == "SOUTH" then
          close_redis(red)
          return kong.response.exit(400, {
            status = false,
            errorCode = "REG-ID-012",
            message = "You already have an account in this region.",
          })
        end
        input_region = "NORTH"
      end
    end

    if not input_region or (input_region ~= "NORTH" and input_region ~= "SOUTH") then
      close_redis(red)
      return kong.response.exit(400, {
        status = false,
        errorCode = "REG-ID-001",
        message = "Target region is required (NORTH or SOUTH)",
      })
    end

    -- AC-20: Idempotency lock to prevent duplicate creation on double-submit
    local lock_key = "lock:create:" .. msisdn
    local lock_res, lock_err = red:set(lock_key, "1", "EX", conf.idempotency_ttl_seconds, "NX")
    close_redis(red)

    if not lock_res or lock_res == ngx.null then
      return kong.response.exit(429, {
        status = false,
        errorCode = "PIN-017",
        message = "Your request is already being processed. Please wait.",
      })
    end

    -- Route upstream to target region backend
    local upstream = (input_region == "NORTH") and conf.north_upstream or conf.south_upstream
    local set_ok, set_err = kong.service.set_upstream(upstream)
    if not set_ok then
      kong.log.err("switch-account: set_upstream failed for ", upstream, ": ", set_err)
      return kong.response.exit(503, {
        status = false,
        errorCode = "SW_008",
        message = "Backend routing unavailable",
      })
    end

    kong.service.request.set_header("X-Region", input_region)
    if state and state.guid then
      kong.service.request.set_header("X-Passport-Guid", tostring(state.guid))
    end
    if device_id then
      kong.service.request.set_header("X-Device-Id", device_id)
    end

    kong.ctx.plugin.action = "CREATE_SECOND_WALLET"
    kong.ctx.plugin.targetRegion = input_region
    return
  end
end

function SwitchAccount:header_filter(conf)
  if conf.strip_internal_names then
    ngx.header["Content-Length"] = nil
  end
end

function SwitchAccount:body_filter(conf)
  if not conf.strip_internal_names then
    return
  end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]

  local buffer = kong.ctx.shared.switch_body or ""
  if chunk and chunk ~= "" then
    buffer = buffer .. chunk
  end
  kong.ctx.shared.switch_body = buffer

  if not eof then
    ngx.arg[1] = nil
    return
  end

  -- Scrub internal names (Telepin, YottaGet) as mandated by §2.1
  local sanitized = buffer:gsub("[Tt]elepin", "Core Banking"):gsub("[Yy]otta[Gg]et", "Core Banking")
  ngx.arg[1] = sanitized
end

function SwitchAccount:log(conf)
  if not conf.audit_logging_enabled then
    return
  end

  local ctx = kong.ctx.plugin
  if not ctx then
    return
  end

  local status = kong.response.get_status()
  local latency = ngx.now() - (ctx.startTime or ngx.now())

  local event_name = "switch_access"
  if ctx.action == "SWITCH" then
    event_name = (status < 400) and "switch_completed" or "switch_failed"
  elseif ctx.action == "SET_DEVICE_DEFAULT" then
    event_name = (status < 400) and "default_wallet_changed" or "default_wallet_change_failed"
  elseif ctx.action == "CREATE_SECOND_WALLET" then
    event_name = (status < 400) and "account_created" or "account_creation_validation_failed"
  end

  local audit_entry = {
    event = event_name,
    msisdn = ctx.msisdn,
    deviceId = ctx.deviceId,
    path = ctx.path,
    targetRegion = ctx.targetRegion,
    targetAccountId = ctx.targetAccountId,
    httpStatus = status,
    latencyMs = math.floor(latency * 1000),
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }

  kong.log.info("switch-account-audit: ", cjson.encode(audit_entry))
end

return SwitchAccount
