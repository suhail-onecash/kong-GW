-- kong/plugins/identity-matrix/schema.lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "identity-matrix",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Redis Configuration
          { redis_host = { type = "string", required = true, default = "host.docker.internal" } },
          { redis_port = { type = "integer", required = true, default = 6379, between = { 1, 65535 } } },
          { redis_timeout = { type = "integer", required = true, default = 1000 } },
          { passport_prefix = { type = "string", required = true, default = "passport:" } },

          -- Upstreams
          { north_upstream = { type = "string", required = true, default = "north-backend" } },
          { south_upstream = { type = "string", required = true, default = "south-backend" } },

          -- Request extraction
          { msisdn_header = { type = "string", required = true, default = "X-MSISDN" } },
          { msisdn_body_field = { type = "string", required = true, default = "username" } },
          { device_id_header = { type = "string", required = true, default = "X-Device-Id" } },
          { region_header = { type = "string", required = true, default = "X-Target-Region" } },
          { region_body_field = { type = "string", required = true, default = "region" } },

          -- Endpoint path mapping
          { login_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/NWC/rest/Login", "/NWC/rest/login", "/NWC/rest/login2", "/AGENT/rest/Login", "/AGENT/rest/login" }
          } },
          { register_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/NWC/rest/register", "/NWC/rest/Register", "/NWC/rest/signup", "/NWC/rest/SignUp" }
          } },
          { precheck_paths = {
              type = "array",
              elements = { type = "string" },
              default = { "/NWC/rest/identity/check", "/identity/check", "/identity/precheck" }
          } },

          -- Header forwarding & security
          { send_trusted_headers = { type = "boolean", required = true, default = true } },
          { strip_internal_names = { type = "boolean", required = true, default = true } },
          { idempotency_ttl_seconds = { type = "integer", required = true, default = 10 } },
          { audit_logging_enabled = { type = "boolean", required = true, default = true } },
        },
    } },
  },
}
