-- kong/plugins/dual-login/schema.lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "dual-login",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { north_target = { type = "string", required = true, default = "10.200.31.18:8080" } },
          { south_target = { type = "string", required = true, default = "10.200.114.22:8080" } },
          { north_login_path = { type = "string", required = true, default = "/NWC/rest/login" } },
          { south_login_path = { type = "string", required = true, default = "/NWC/rest/login" } },
          { msisdn_header = { type = "string", required = true, default = "X-MSISDN" }, },
          { south_payload_file = { type = "string", required = false, default = "/usr/local/share/lua/5.1/kong/plugins/dual-login/south_payload.json" } },
          { connect_timeout = { type = "integer", required = true, default = 5000 } },
          { read_timeout = { type = "integer", required = true, default = 10000 } },
          { send_timeout = { type = "integer", required = true, default = 5000 } },
          { retry_count = { type = "integer", required = false, default = 1 } },
        },
    } },
  },
}
