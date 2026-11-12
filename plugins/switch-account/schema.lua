-- plugins/switch-account/schema.lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "switch-account",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          { redis_host = { type = "string", default = "127.0.0.1" } },
          { redis_port = { type = "integer", default = 6379 } },
          { redis_timeout = { type = "integer", default = 1000 } },
          { passport_prefix = { type = "string", default = "passport:" } },
          { msisdn_header = { type = "string", default = "X-MSISDN" } },
          { device_id_header = { type = "string", default = "X-Device-Id" } },
          { region_header = { type = "string", default = "X-Target-Region" } },
          { north_upstream = { type = "string", default = "north-backend" } },
          { south_upstream = { type = "string", default = "south-backend" } },
          {
            decision_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/switch/decision", "/NWC/rest/switch/decision" }
            }
          },
          {
            switch_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/switch/authenticate", "/NWC/rest/switch/authenticate" }
            }
          },
          {
            set_default_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/switch/set-default", "/NWC/rest/switch/set-default" }
            }
          },
          {
            create_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/switch/create", "/NWC/rest/register/second-account" }
            }
          },
          { strip_internal_names = { type = "boolean", default = true } },
          { idempotency_ttl_seconds = { type = "integer", default = 10 } },
          { audit_logging_enabled = { type = "boolean", default = true } },
        },
      },
    },
  },
}
