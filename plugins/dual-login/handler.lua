-- kong/plugins/dual-login/handler.lua
-- Simplified Dual-Region Login Plugin (Matches exact diagram sequence):
--   1. App -> Kong: Login2
--   2. Kong -> North: Login
--   3. North -> Kong: Return response
--   4. Kong -> South: Login (only if North succeeds, reads south_payload from json file)
--   5. South -> Kong: Return response
--   6. Kong -> App: Return response

local http = require "resty.http"
local cjson = require "cjson.safe"

local DualLogin = {
  VERSION = "1.0.0",
  PRIORITY = 940,
}

local function build_url(target, path)
  local base = target
  if not string.match(base, "^https?://") then
    base = "http://" .. base
  end
  base = string.gsub(base, "/$", "")
  if not string.match(path, "^/") then
    path = "/" .. path
  end
  return base .. path
end

local function is_login_success(status, data)
  if not status or status < 200 or status >= 300 then
    return false
  end
  if type(data) ~= "table" then
    return false
  end

  -- Explicit non-zero errorNumber or errorNo means failure (e.g. 99887716, 9988771)
  local err_code = data.errorNumber or data.errorNo
  if err_code ~= nil and tonumber(err_code) ~= 0 then
    return false
  end

  -- Check mainResponse.errorNo if present
  if data.mainResponse and type(data.mainResponse) == "table" then
    if data.mainResponse.errorNo ~= nil and tonumber(data.mainResponse.errorNo) ~= 0 then
      return false
    end
  end

  -- Presence of token or errorNumber == 0 indicates success
  if (data.tokenValNorth and data.tokenValNorth ~= "") or
     (data.tokenValSouth and data.tokenValSouth ~= "") or
     (data.token and data.token ~= "") or
     (data.errorNumber == 0) then
    return true
  end

  return data.status == true
end

local function load_south_payload(file_path, fallback)
  local candidate_paths = {
    file_path,
    "/usr/local/share/lua/5.1/kong/plugins/dual-login/south_payload.json",
    "./plugins/dual-login/south_payload.json",
    "south_payload.json",
  }

  for _, path in ipairs(candidate_paths) do
    if path and path ~= "" then
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
          local parsed = cjson.decode(content)
          if parsed and type(parsed) == "table" then
            kong.log.info("dual-login: Successfully loaded south_payload from file: ", path)
            return parsed
          end
        end
      end
    end
  end

  kong.log.warn("dual-login: Unable to load south_payload from file candidate paths, falling back to request body")
  return fallback
end

-- Classify HTTP/connection errors into appropriate Kong upstream status codes.
-- timeout      -> 504 Gateway Timeout
-- refused/dns  -> 502 Bad Gateway
-- everything else -> 502 Bad Gateway (default)
local function classify_http_error(err)
  local e = tostring(err or ""):lower()
  if string.find(e, "timeout") then
    return 504 -- Gateway Timeout
  end
  if string.find(e, "refused") then
    return 502 -- Bad Gateway
  end
  if string.find(e, "no resolved") or string.find(e, "host not found") or string.find(e, "dns") then
    return 502 -- Bad Gateway (DNS resolution failure)
  end
  if string.find(e, "closed") or string.find(e, "reset") or string.find(e, "broken") then
    return 502 -- Bad Gateway
  end
  return 502 -- Default: Bad Gateway
end

local function make_http_call(conf, target, path, payload, extra_headers)
  local url = build_url(target, path)
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if extra_headers then
    for k, v in pairs(extra_headers) do
      headers[k] = v
    end
  end

  local body_str = type(payload) == "string" and payload or cjson.encode(payload)

  kong.log.info("dual-login: [HTTP OUT] POST to ", url, " | payload_bytes=", string.len(body_str or ""))

  local max_retries = tonumber(conf.retry_count) or 0
  local attempt = 0
  local res, err, err_status

  repeat
    attempt = attempt + 1
    local httpc = http.new()
    httpc:set_timeouts(conf.connect_timeout or 5000, conf.send_timeout or 5000, conf.read_timeout or 10000)

    res, err = httpc:request_uri(url, {
      method = "POST",
      body = body_str,
      headers = headers,
    })

    if res then
      break
    end

    -- Retry only transient failures (timeout / connection refused)
    if attempt <= max_retries then
      err_status = classify_http_error(err)
      local is_transient = (err_status == 504) or string.find(tostring(err or ""):lower(), "refused")
      if is_transient then
        kong.log.warn("dual-login: [HTTP RETRY] Attempt ", attempt, " failed for ", url, ": ", tostring(err), " -> retrying in 500ms")
        ngx.sleep(0.5)
      else
        break
      end
    end
  until attempt > max_retries

  if not res then
    err_status = err_status or classify_http_error(err)
    kong.log.err("dual-login: [HTTP ERROR] Call to ", url, " failed after ", attempt, " attempt(s): ", tostring(err), " | status=", err_status)
    return nil, err, err_status
  end

  local body = res.body or ""
  local json_body = cjson.decode(body)
  kong.log.info("dual-login: [HTTP IN] Response from ", url, " | status=", res.status, " body_bytes=", string.len(body))

  return {
    status = res.status,
    raw_body = body,
    data = json_body or body,
  }, nil, nil
end

function DualLogin:access(conf)
  if kong.request.get_method() ~= "POST" then
    return kong.response.exit(405, { message = "Method Not Allowed. Use POST." })
  end

  -- Robust body reading for OpenResty
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

  -- Get MSISDN from header (defined in plugin config as msisdn_header)
  local msisdn = kong.request.get_header(conf.msisdn_header)
  kong.log.info("dual-login: msisdn=",msisdn)

  local req_body = nil
  if raw_body and raw_body ~= "" then
    req_body = cjson.decode(raw_body)
  end

  if not req_body or type(req_body) ~= "table" then
    req_body = kong.request.get_body()
  end

  if not req_body or type(req_body) ~= "table" then
    kong.log.warn("dual-login: Invalid or missing JSON body in request. raw_body_len=", string.len(raw_body or ""))
    return kong.response.exit(400, {
      error = "Invalid JSON body",
      message = "Request body must be a valid JSON object"
    })
  end

  local username = req_body.username or req_body.msisdn or ""
  local device = tostring(req_body.device or "unknown")
  local app_version = tostring(req_body.appVersion or "unknown")

  kong.log.info("dual-login: [START] Incoming Login2 request | username=", username, " device=", device, " appVersion=", app_version)

  local headers = {
    ["X-MSISDN"] = username,
  }

  -- ------------------------------------------------------------------------
  -- STEP 1 (Diagram): Kong -> North: Login
  -- ------------------------------------------------------------------------
  kong.log.info("dual-login: [STEP 1] Calling North Login | target=", conf.north_target, " path=", conf.north_login_path, " username=", username)

  local north_res, north_err, north_err_status = make_http_call(
    conf,
    conf.north_target,
    conf.north_login_path,
    raw_body or req_body,
    headers
  )

  -- ------------------------------------------------------------------------
  -- STEP 2 (Diagram): North -> Kong: Return response
  -- ------------------------------------------------------------------------
  local north_data = north_res and north_res.data
  if type(north_data) ~= "table" then
    north_data = {}
  end
  local north_status = (north_res and north_res.status) or north_err_status or 502
  local north_error_no = (north_data.errorNumber or north_data.errorNo) or "nil"
  local north_des = north_data.des or ""
  north_data.service="North"

  -- If North fails -> Return proper exception response to App (South is never called)
  if not is_login_success(north_status, north_data) then
    kong.log.info("dual-login: [STEP 2] North Login FAILED | status=", north_status, " errorNumber=", tostring(north_error_no), " des=", tostring(north_des), " -> Halting chain. South will NOT be called.")

    -- Connection failure / timeout: no HTTP response received at all.
    -- Return a proper exception response with the upstream error details.
    if not north_res then
      return kong.response.exit(north_status, {
        error = "upstream_connection_failed",
        message = "North login service unreachable",
        status = false,
        served_byNorth = "north",
        request_msisdn = username,
        upstream_error = tostring(north_err),
        upstream_status = north_status,
      })
    end

    -- Upstream returned an HTTP response but it indicated failure.
    return kong.response.exit(north_status, north_data or {
      errorNumber = 99887716,
      des = north_err or "North login failed",
      status = false,
      served_byNorth = "north",
      request_msisdn = username,
      upstream_error = north_err,
    })
  end

  -- North succeeded! Extract token
  local north_token = north_data.tokenValNorth or north_data.token
  local token_len = north_token and string.len(north_token) or 0
  local token_preview = north_token and (string.sub(north_token, 1, 16) .. "...") or "nil"

  kong.log.info("dual-login: [STEP 2] North Login SUCCEEDED | status=", north_status, " errorNumber=", tostring(north_error_no), " tokenValNorth=", token_preview, " (len=", token_len, ") -> Proceeding to South Login.")

  -- ------------------------------------------------------------------------
  -- STEP 3 (Diagram): Kong -> South: Login
  -- Read south_payload from configured JSON file
  -- ------------------------------------------------------------------------
  local south_payload = load_south_payload(conf.south_payload_file, req_body)  -- just -For- Development

  -- Preserve the active username if provided in request
  if username and username ~= "" then
    south_payload.username = username
  end

  if north_token then
    headers["X-North-Token"] = tostring(north_token)
  end

  local pass_preview = string.sub(tostring(south_payload.pass or ""), 1, 8) .. "..."
  local hash_preview = string.sub(tostring(south_payload.hash or ""), 1, 8) .. "..."
  kong.log.info("dual-login: [STEP 3] Calling South Login | target=", conf.south_target, " path=", conf.south_login_path, " username=", tostring(south_payload.username), " pass=", pass_preview, " hash=", hash_preview, " timeStp=", tostring(south_payload.timeStp))

  local south_res, south_err, south_err_status = make_http_call(
    conf,
    conf.south_target,
    conf.south_login_path,
    south_payload,
    headers
  )

  -- ------------------------------------------------------------------------
  -- STEP 4 (Diagram): South -> Kong: Return response
  -- ------------------------------------------------------------------------
  local south_data = south_res and south_res.data
  if type(south_data) ~= "table" then
    south_data = {}
  end
  local south_status = (south_res and south_res.status) or south_err_status or 502
  local south_error_no = (south_data.errorNumber or south_data.errorNo) or "nil"
  local south_des = south_data.des or ""
  south_data.service="South"

  -- If South fails -> Return South failure response to App
  if not is_login_success(south_status, south_data) then
    kong.log.info("dual-login: [STEP 4] South Login FAILED | status=", south_status, " errorNumber=", tostring(south_error_no), " des=", tostring(south_des), " -> Returning South failure to App.")

    -- Connection failure / timeout: no HTTP response received at all.
    -- Return a proper exception response with the upstream error details.
    if not south_res then
      return kong.response.exit(south_status, {
        error = "upstream_connection_failed",
        message = "South login service unreachable",
        status = false,
        served_bySouth = "south",
        request_msisdn = username,
        upstream_error = tostring(south_err),
        upstream_status = south_status,
      })
    end

    -- Upstream returned an HTTP response but it indicated failure.
    return kong.response.exit(south_status, south_data or {
      errorNumber = 99887717,
      des = south_err or "South login failed",
      status = false,
      served_bySouth = "south",
      request_msisdn = username,
      upstream_error = south_err,
    })
  end

  local south_token = (type(south_data) == "table") and (south_data.tokenValSouth or south_data.token) or nil
  local south_token_len = south_token and string.len(south_token) or 0
  local south_token_preview = south_token and (string.sub(south_token, 1, 16) .. "...") or "nil"

  kong.log.info("dual-login: [STEP 4] South Login SUCCEEDED | status=", south_status, " errorNumber=", tostring(south_error_no), " tokenValSouth=", south_token_preview, " (len=", south_token_len, ")")

  -- ------------------------------------------------------------------------
  -- STEP 5 (Diagram): Kong -> App: Return response (Combined Success)
  -- ------------------------------------------------------------------------
  local final_response = north_data
  if type(south_data) == "table" and south_data.accountCheckResponse and not final_response.accountCheckResponse then
    final_response.accountCheckResponse = south_data.accountCheckResponse
  end

  final_response.southResponse = south_data
  kong.log.info("dual-login: [STEP 5] Both North and South logins succeeded. Enriched response with tokenValSouth. Returning 200 OK to App for username=", username)
  kong.response.set_header("X-API-Key", "KEY-123456")
  return kong.response.exit(200, final_response)
end

return DualLogin