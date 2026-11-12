-- kong/plugins/payment-transfer/schema.lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "payment-transfer",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { redis_host = { type = "string", required = true, default = "host.docker.internal" } },
          { redis_port = { type = "integer", required = true, default = 6379, between = { 1, 65535 } } },
          { redis_timeout = { type = "integer", required = true, default = 1000 } },
          { redis_password = { type = "string", required = false } },
          { redis_tx_prefix = { type = "string", required = true, default = "payment:tx:" } },
          { redis_queue_key = { type = "string", required = true, default = "payment:compensation:queue" } },
          { tx_ttl_seconds = { type = "integer", required = true, default = 86400 } },

          { north_target = { type = "string", required = true, default = "10.200.31.18:8080" } },
          { south_target = { type = "string", required = true, default = "10.200.114.22:8080" } },

          { north_debit_path = { type = "string", required = true, default = "/api/debit" } },
          { south_credit_path = { type = "string", required = true, default = "/api/credit" } },
          { south_status_path = { type = "string", required = true, default = "/api/credit/status" } },
          { north_reversal_path = { type = "string", required = true, default = "/api/debit/reverse" } },

          { connect_timeout = { type = "integer", required = true, default = 2000 } },
          { read_timeout = { type = "integer", required = true, default = 5000 } },
          { send_timeout = { type = "integer", required = true, default = 3000 } },
          { keepalive_timeout = { type = "integer", required = true, default = 60000 } },
          { keepalive_pool_size = { type = "integer", required = true, default = 100 } },

          { max_reversal_retries = { type = "integer", required = true, default = 3 } },
          { retry_delay_seconds = { type = "integer", required = true, default = 5 } },
        },
    } },
  },
}
