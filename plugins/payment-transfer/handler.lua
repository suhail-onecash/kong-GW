-- kong/plugins/payment-transfer/handler.lua
-- Option A Safe Cross-Region Payment Transfer Plugin
-- Implements the 5 safety mechanisms:
--   1. Cosocket non-blocking HTTP + keepalive connection pooling (resty.http)
--   2. Write-Ahead Transaction State Machine in Redis with idempotency checks
--   3. Destination status inquiry to resolve timeout ambiguity before rollback
--   4. Automated rollback/reversal on source account if destination credit fails
--   5. Asynchronous background retry worker (ngx.timer.at) + Redis Dead Letter Queue

local redis = require "resty.redis"
local http = require "resty.http"
local cjson = require "cjson.safe"

local PaymentTransfer = {
  VERSION = "1.0.0",
  PRIORITY = 950,
}

-- --------------------------------------------------------------------------
-- Helper: Generate UUID (with fallback if utils unavailable)
-- --------------------------------------------------------------------------
local function generate_uuid()
  local ok, utils = pcall(require, "kong.tools.utils")
  if ok and utils and utils.uuid then
    return utils.uuid()
  end
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

-- --------------------------------------------------------------------------
-- Helper: Redis Connection & Pool Management
-- --------------------------------------------------------------------------
local function get_redis(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    kong.log.err("payment-transfer: redis connect failed: ", err)
    return nil, err
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local auth_ok, auth_err = red:auth(conf.redis_password)
    if not auth_ok then
      kong.log.err("payment-transfer: redis auth failed: ", auth_err)
      return nil, auth_err
    end
  end

  return red, nil
end

local function close_redis(red)
  if not red then return end
  local ok, err = red:set_keepalive(60000, 50)
  if not ok then
    kong.log.warn("payment-transfer: redis set_keepalive failed: ", err)
  end
end

-- --------------------------------------------------------------------------
-- Helper: Format Target URL
-- --------------------------------------------------------------------------
local function build_url(target, path)
  local base = target
  if not string.match(base, "^https?://") then
    base = "http://" .. base
  end
  -- remove trailing slash if any
  base = string.gsub(base, "/$", "")
  -- ensure path starts with /
  if not string.match(path, "^/") then
    path = "/" .. path
  end
  return base .. path
end

-- --------------------------------------------------------------------------
-- Mechanism 1: Cosocket Non-blocking HTTP with Connection Pooling
-- --------------------------------------------------------------------------
local function make_http_call(conf, target, path, method, payload, extra_headers)
  local httpc = http.new()
  httpc:set_timeouts(conf.connect_timeout, conf.send_timeout, conf.read_timeout)

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

  local body_str = nil
  if payload then
    body_str = type(payload) == "string" and payload or cjson.encode(payload)
  end

  kong.log.info("payment-transfer: making HTTP call [", method, "] to ", url)
  local res, err = httpc:request_uri(url, {
    method = method,
    body = body_str,
    headers = headers,
    keepalive_timeout = conf.keepalive_timeout,
    keepalive_pool = conf.keepalive_pool_size,
  })

  if not res then
    kong.log.err("payment-transfer: HTTP call to ", url, " failed: ", err)
    return nil, err
  end

  local body = res.body or ""
  local json_body = cjson.decode(body)
  return {
    status = res.status,
    headers = res.headers,
    raw_body = body,
    data = json_body or body,
  }, nil
end

-- --------------------------------------------------------------------------
-- Mechanism 2: Update Transaction State in Redis
-- --------------------------------------------------------------------------
local function update_tx_state(conf, tx_id, patch)
  local red, err = get_redis(conf)
  if not red then return nil, err end

  local key = conf.redis_tx_prefix .. tx_id
  local raw, get_err = red:get(key)
  if get_err or not raw or raw == ngx.null then
    close_redis(red)
    return nil, "Transaction key not found"
  end

  local state = cjson.decode(raw) or {}
  for k, v in pairs(patch) do
    state[k] = v
  end
  state.updatedAt = ngx.time()

  local ok, set_err = red:set(key, cjson.encode(state), "EX", conf.tx_ttl_seconds)
  close_redis(red)
  return ok, set_err
end

-- --------------------------------------------------------------------------
-- Mechanism 5: Asynchronous Background Retry Worker (ngx.timer.at)
-- Retries North reversal if immediate rollback failed
-- --------------------------------------------------------------------------
local function background_reversal_worker(premature, context)
  if premature then
    return
  end

  local conf = context.conf
  local tx_id = context.tx_id
  local sender_msisdn = context.sender_msisdn
  local amount = context.amount
  local max_retries = conf.max_reversal_retries or 3
  local delay = conf.retry_delay_seconds or 5

  kong.log.warn("payment-transfer [background]: starting reversal retry worker for tx: ", tx_id)

  local rollback_payload = {
    transactionId = tx_id,
    originalTxId = tx_id,
    msisdn = sender_msisdn,
    amount = amount,
    reason = "SOUTH_CREDIT_FAILED_ASYNC_RETRY",
  }

  local success = false
  for attempt = 1, max_retries do
    kong.log.info("payment-transfer [background]: reversal attempt ", attempt, " for tx: ", tx_id)
    local res, err = make_http_call(
      conf,
      conf.north_target,
      conf.north_reversal_path,
      "POST",
      rollback_payload,
      { ["X-Transaction-Id"] = tx_id, ["X-Retry-Attempt"] = tostring(attempt) }
    )

    if res and (res.status == 200 or res.status == 201 or res.status == 204) then
      kong.log.info("payment-transfer [background]: reversal succeeded on attempt ", attempt, " for tx: ", tx_id)
      success = true
      update_tx_state(conf, tx_id, {
        status = "REVERSED",
        reversedAt = ngx.time(),
        reversalAttempt = attempt,
      })
      break
    else
      kong.log.err("payment-transfer [background]: reversal attempt ", attempt, " failed: ", tostring(err or (res and res.status)))
      if attempt < max_retries then
        ngx.sleep(delay)
      end
    end
  end

  if not success then
    kong.log.err("payment-transfer [background]: ALL reversal retries failed for tx: ", tx_id, ". Enqueueing to Dead Letter Queue.")
    update_tx_state(conf, tx_id, {
      status = "NEEDS_RECONCILIATION",
      reconciliationReason = "NORTH_REVERSAL_EXHAUSTED",
      updatedAt = ngx.time(),
    })

    -- Push to Redis Dead Letter Queue for operator/cron reconciliation
    local red, r_err = get_redis(conf)
    if red then
      local queue_item = cjson.encode({
        txId = tx_id,
        senderMsisdn = sender_msisdn,
        amount = amount,
        timestamp = ngx.time(),
        error = "North reversal failed after all retries",
      })
      red:rpush(conf.redis_queue_key, queue_item)
      close_redis(red)
    end
  end
end

-- --------------------------------------------------------------------------
-- Main Handler: Access Phase
-- --------------------------------------------------------------------------
function PaymentTransfer:access(conf)
  -- 1. Validate HTTP Method
  local method = kong.request.get_method()
  if method ~= "POST" then
    return kong.response.exit(405, { message = "Method Not Allowed. Use POST." })
  end

  -- 2. Read and Validate Request Body
  local req_body, err = kong.request.get_body("application/json")
  if not req_body or type(req_body) ~= "table" then
    return kong.response.exit(400, {
      error = "Invalid JSON body",
      message = "Request body must be a valid JSON object"
    })
  end

  local sender_msisdn = req_body.senderMsisdn or req_body.northMsisdn or req_body.fromMsisdn
  local receiver_msisdn = req_body.receiverMsisdn or req_body.southMsisdn or req_body.toMsisdn
  local amount = tonumber(req_body.amount)
  local currency = req_body.currency or "USD"

  if not sender_msisdn or sender_msisdn == "" then
    return kong.response.exit(400, { error = "Missing senderMsisdn" })
  end
  if not receiver_msisdn or receiver_msisdn == "" then
    return kong.response.exit(400, { error = "Missing receiverMsisdn" })
  end
  if not amount or amount <= 0 then
    return kong.response.exit(400, { error = "Invalid amount: must be greater than 0" })
  end

  -- 3. Extract or Generate Idempotency Key / Transaction ID
  local header_tx_id = kong.request.get_header("X-Transaction-Id")
  local tx_id = header_tx_id or req_body.transactionId or req_body.txId or generate_uuid()

  -- 4. Connect to Redis & Check Idempotency (Write-Ahead State)
  local red, red_err = get_redis(conf)
  if not red then
    return kong.response.exit(503, { error = "State store unavailable (Redis error)", details = red_err })
  end

  local tx_key = conf.redis_tx_prefix .. tx_id
  local existing_raw, get_err = red:get(tx_key)
  if get_err then
    close_redis(red)
    return kong.response.exit(503, { error = "Redis read error", details = get_err })
  end

  if existing_raw and existing_raw ~= ngx.null and existing_raw ~= "" then
    close_redis(red)
    local existing = cjson.decode(existing_raw) or {}
    local curr_status = existing.status or "UNKNOWN"

    if curr_status == "COMPLETED" then
      return kong.response.exit(200, {
        message = "Transaction already completed (idempotent replay)",
        transactionId = tx_id,
        status = curr_status,
        data = existing,
      })
    elseif curr_status == "PENDING" or curr_status == "NORTH_DEBITED" then
      return kong.response.exit(409, {
        error = "Transaction currently in progress",
        transactionId = tx_id,
        status = curr_status,
      })
    else
      return kong.response.exit(400, {
        error = "Transaction previously processed with final status: " .. curr_status,
        transactionId = tx_id,
        status = curr_status,
      })
    end
  end

  -- Initial Write-Ahead Record
  local initial_state = {
    txId = tx_id,
    senderMsisdn = sender_msisdn,
    receiverMsisdn = receiver_msisdn,
    amount = amount,
    currency = currency,
    status = "PENDING",
    createdAt = ngx.time(),
    updatedAt = ngx.time(),
  }

  local set_ok, set_err = red:set(tx_key, cjson.encode(initial_state), "EX", conf.tx_ttl_seconds)
  close_redis(red)
  if not set_ok then
    return kong.response.exit(503, { error = "Failed to initialize transaction state", details = set_err })
  end

  -- ------------------------------------------------------------------------
  -- PHASE 1: Debit Customer MSISDN on North
  -- ------------------------------------------------------------------------
  local debit_payload = {
    transactionId = tx_id,
    msisdn = sender_msisdn,
    amount = amount,
    currency = currency,
  }

  local debit_res, debit_err = make_http_call(
    conf,
    conf.north_target,
    conf.north_debit_path,
    "POST",
    debit_payload,
    { ["X-Transaction-Id"] = tx_id }
  )

  if not debit_res or (debit_res.status < 200 or debit_res.status >= 300) then
    local status_code = (debit_res and debit_res.status) or 502
    local err_msg = (debit_res and debit_res.data) or debit_err or "Debit call failed"
    update_tx_state(conf, tx_id, {
      status = "DEBIT_FAILED",
      debitError = err_msg,
    })
    return kong.response.exit(status_code, {
      error = "North Debit Failed",
      transactionId = tx_id,
      details = err_msg,
    })
  end

  -- North Debit Succeeded! Update State
  update_tx_state(conf, tx_id, {
    status = "NORTH_DEBITED",
    northDebitResponse = debit_res.data,
  })

  -- ------------------------------------------------------------------------
  -- PHASE 2: Credit Customer MSISDN on South
  -- ------------------------------------------------------------------------
  local credit_payload = {
    transactionId = tx_id,
    msisdn = receiver_msisdn,
    amount = amount,
    currency = currency,
  }

  local credit_res, credit_err = make_http_call(
    conf,
    conf.south_target,
    conf.south_credit_path,
    "POST",
    credit_payload,
    { ["X-Transaction-Id"] = tx_id }
  )

  local credit_succeeded = false
  local needs_inquiry = false

  if credit_res and (credit_res.status >= 200 and credit_res.status < 300) then
    credit_succeeded = true
  elseif not credit_res then
    -- Network failure or read timeout!
    needs_inquiry = true
  end

  -- ------------------------------------------------------------------------
  -- PHASE 3: Status Inquiry (Resolve Timeout Ambiguity before Rollback)
  -- ------------------------------------------------------------------------
  if needs_inquiry then
    kong.log.warn("payment-transfer: South credit timed out. Querying status before attempting rollback for tx: ", tx_id)
    local query_path = conf.south_status_path .. "?transactionId=" .. tx_id
    local inq_res, inq_err = make_http_call(
      conf,
      conf.south_target,
      query_path,
      "GET",
      nil,
      { ["X-Transaction-Id"] = tx_id }
    )

    if inq_res and inq_res.status == 200 and inq_res.data and type(inq_res.data) == "table" then
      local s = string.upper(tostring(inq_res.data.status or inq_res.data.state or ""))
      if s == "SUCCESS" or s == "COMPLETED" or s == "CREDITED" then
        kong.log.info("payment-transfer: Status inquiry confirmed South credit SUCCESS for tx: ", tx_id)
        credit_succeeded = true
      end
    end
  end

  -- ------------------------------------------------------------------------
  -- PHASE 4: Transaction Finalization (Success vs Compensation)
  -- ------------------------------------------------------------------------
  if credit_succeeded then
    -- Complete Success!
    update_tx_state(conf, tx_id, {
      status = "COMPLETED",
      completedAt = ngx.time(),
    })

    return kong.response.exit(200, {
      statusCode = 200,
      message = "Payment transfer completed successfully",
      transactionId = tx_id,
      status = "COMPLETED",
      senderMsisdn = sender_msisdn,
      receiverMsisdn = receiver_msisdn,
      amount = amount,
      currency = currency,
    })
  end

  -- ------------------------------------------------------------------------
  -- PHASE 5: Rollback / Reversal on North
  -- ------------------------------------------------------------------------
  kong.log.err("payment-transfer: South credit failed/unconfirmed. Initiating North reversal for tx: ", tx_id)

  local rollback_payload = {
    transactionId = tx_id,
    originalTxId = tx_id,
    msisdn = sender_msisdn,
    amount = amount,
    reason = "SOUTH_CREDIT_FAILED",
  }

  local rev_res, rev_err = make_http_call(
    conf,
    conf.north_target,
    conf.north_reversal_path,
    "POST",
    rollback_payload,
    { ["X-Transaction-Id"] = tx_id }
  )

  if rev_res and (rev_res.status == 200 or rev_res.status == 201 or rev_res.status == 204) then
    -- Immediate Rollback Succeeded
    update_tx_state(conf, tx_id, {
      status = "REVERSED",
      reversedAt = ngx.time(),
    })

    return kong.response.exit(502, {
      error = "Transfer failed on destination account",
      message = "South credit failed. Funds have been refunded to North MSISDN.",
      transactionId = tx_id,
      status = "REVERSED",
    })
  else
    -- Immediate Rollback Failed: Schedule Background Asynchronous Worker
    kong.log.err("payment-transfer: Immediate North reversal failed: ", tostring(rev_err or (rev_res and rev_res.status)), ". Scheduling async retry timer.")
    update_tx_state(conf, tx_id, {
      status = "ROLLBACK_PENDING_RETRY",
      rollbackError = tostring(rev_err or (rev_res and rev_res.status)),
    })

    local context = {
      conf = conf,
      tx_id = tx_id,
      sender_msisdn = sender_msisdn,
      amount = amount,
    }

    local timer_ok, timer_err = ngx.timer.at(0, background_reversal_worker, context)
    if not timer_ok then
      kong.log.err("payment-transfer: Failed to schedule timer: ", timer_err, ". Enqueueing directly to Dead Letter Queue.")
      local dead_red, _ = get_redis(conf)
      if dead_red then
        dead_red:rpush(conf.redis_queue_key, cjson.encode(context))
        close_redis(dead_red)
      end
    end

    return kong.response.exit(502, {
      error = "Transfer failed on destination account",
      message = "South credit failed. Source refund is in progress.",
      transactionId = tx_id,
      status = "ROLLBACK_PENDING",
    })
  end
end

return PaymentTransfer
