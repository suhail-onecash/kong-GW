-- kong/plugins/passport-router/schema.lua
-- Plugin Configuration panel from the "Passport Router Plugin - Request Flow" diagram.
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "passport-router",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { redis_host = { type = "string", required = true, default = "host.docker.internal" }, },
          { redis_port = { type = "integer", required = true, default = 6379, between = { 1, 65535 } }, },
          { redis_timeout = { type = "integer", required = true, default = 1000 }, },
          { passport_prefix = { type = "string", required = true, default = "passport:" }, },
          { msisdn_header = { type = "string", required = true, default = "X-MSISDN" }, },
          { north_upstream = { type = "string", required = true, default = "north-backend" }, },
          { south_upstream = { type = "string", required = true, default = "south-backend" }, },
          { response_transform_enabled = { type = "boolean", required = false, default = false } },
          { add_region_response_header = { type = "boolean", required = false, default = false } },
          { north_field_map = { type = "string", required = false, default = "{}" } },
          { south_field_map = { type = "string", required = false, default = "{}" } },
          { north_add_fields = { type = "string", required = false, default = "{}" } },
          { south_add_fields = { type = "string", required = false, default = "{}" } },
          { north_delete_fields = { type = "string", required = false, default = "{}" } },
          { south_delete_fields = { type = "string", required = false, default = "{}" } },
          { north_add_headers = { type = "string", required = false, default = "{}" } },
          { south_add_headers = { type = "string", required = false, default = "{}" } },
          { north_delete_headers = { type = "string", required = false, default = "{}" } },
          { south_delete_headers = { type = "string", required = false, default = "{}" } },
        },
    }, },
  },
}
