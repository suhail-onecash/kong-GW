# kong/kong.yml.tpl — SOURCE OF TRUTH for the DB-less declarative config.
# This file is a template: environment-specific values are ${TOKEN}s.
#
#   - Structure changes (routes, services, plugins)  -> edit THIS file
#   - Environment values (hostnames, ports, redis)   -> edit kong/vars.<env>.json
#
# kong/kong.yml is generated and gitignored — never edit it directly.
# Tokens are ${VAR}-style so Linux CI can also render via: envsubst < kong/kong.yml.tpl > kong/kong.yml
#
# Route gating (same passport rules on both services):
#   /NWC  -> customer apps  (customer-svc)
#   /AGENT -> agent apps    (agent-svc)

_format_version: "3.0"

upstreams:
  - name: north-backend
    targets:
      - target: ${NORTH_CUSTOMER_TARGET} # north-customer
  - name: south-backend
    targets:
      - target: ${SOUTH_CUSTOMER_TARGET} # south-customer
  - name: north-agent-backend
    targets:
      - target: ${NORTH_AGENT_TARGET} # north-agent
  - name: south-agent-backend
    targets:
      - target: ${SOUTH_AGENT_TARGET} # south-agent

services:
  - name: customer-svc
    host: north-backend # default; plugin overrides per-request via set_upstream
    port: 80
    protocol: http
    routes:
      - name: passport-route
        paths:
          - /NWC
        strip_path: false # forward the full /NWC/... path (backend expects it)
    plugins:
      - name: passport-router
        config:
          redis_host: ${REDIS_HOST}
          redis_port: 6379
          redis_timeout: 1000
          passport_prefix: "passport:"
          msisdn_header: "X-MSISDN"
          north_upstream: north-backend
          south_upstream: south-backend
          response_transform_enabled: ${RESPONSE_TRANSFORM_ENABLED}
          add_region_response_header: ${ADD_REGION_RESPONSE_HEADER}
          north_field_map: '${NORTH_FIELD_MAP}'
          south_field_map: '${SOUTH_FIELD_MAP}'
          north_add_fields: '${NORTH_ADD_FIELDS}'
          south_add_fields: '${SOUTH_ADD_FIELDS}'
          north_delete_fields: '${NORTH_DELETE_FIELDS}'
          south_delete_fields: '${SOUTH_DELETE_FIELDS}'
          north_add_headers: '${NORTH_ADD_HEADERS}'
          south_add_headers: '${SOUTH_ADD_HEADERS}'
          north_delete_headers: '${NORTH_DELETE_HEADERS}'
          south_delete_headers: '${SOUTH_DELETE_HEADERS}'

  - name: agent-svc
    host: north-agent-backend # default; plugin overrides per-request via set_upstream
    port: 80
    protocol: http
    routes:
      - name: agent-route
        paths:
          - /AGENT
        strip_path: false # forward the full /AGENT/... path (backend expects it)
    plugins:
      - name: passport-router
        config:
          redis_host: ${REDIS_HOST}
          redis_port: 6379
          redis_timeout: 1000
          passport_prefix: "passport:"
          msisdn_header: "X-MSISDN"
          north_upstream: north-agent-backend
          south_upstream: south-agent-backend
          response_transform_enabled: ${RESPONSE_TRANSFORM_ENABLED}
          add_region_response_header: ${ADD_REGION_RESPONSE_HEADER}
          north_field_map: '${NORTH_FIELD_MAP}'
          south_field_map: '${SOUTH_FIELD_MAP}'
          north_add_fields: '${NORTH_ADD_FIELDS}'
          south_add_fields: '${SOUTH_ADD_FIELDS}'
          north_delete_fields: '${NORTH_DELETE_FIELDS}'
          south_delete_fields: '${SOUTH_DELETE_FIELDS}'
          north_add_headers: '${NORTH_ADD_HEADERS}'
          south_add_headers: '${SOUTH_ADD_HEADERS}'
          north_delete_headers: '${NORTH_DELETE_HEADERS}'
          south_delete_headers: '${SOUTH_DELETE_HEADERS}'

  - name: payment-svc
    host: north-backend
    port: 80
    protocol: http
    routes:
      - name: payment-transfer-route
        paths:
          - /payment/transfer
        strip_path: false
    plugins:
      - name: payment-transfer
        config:
          redis_host: ${REDIS_HOST}
          redis_port: 6379
          redis_timeout: 1000
          north_target: ${NORTH_CUSTOMER_TARGET}
          south_target: ${SOUTH_CUSTOMER_TARGET}
          north_debit_path: "/api/debit"
          south_credit_path: "/api/credit"
          south_status_path: "/api/credit/status"
          north_reversal_path: "/api/debit/reverse"
          connect_timeout: 2000
          read_timeout: 5000
          send_timeout: 3000
          keepalive_timeout: 60000
          keepalive_pool_size: 100
          max_reversal_retries: 3
          retry_delay_seconds: 5

  - name: dual-login-svc
    host: north-backend
    port: 80
    protocol: http
    routes:
      - name: dual-login-route
        paths:
          - /login2
          - /auth/login2
        strip_path: false
    plugins:
      - name: dual-login
        config:
          north_target: ${NORTH_CUSTOMER_TARGET}
          south_target: ${SOUTH_CUSTOMER_TARGET}
          north_login_path: "/NWC/rest/Login"
          south_login_path: "/NWC/rest/Login"
          msisdn_header: "X-MSISDN"
          south_payload_file: "/usr/local/share/lua/5.1/kong/plugins/dual-login/south_payload.json"
          connect_timeout: 5000
          read_timeout: 10000
          send_timeout: 5000

  - name: identity-svc
    host: north-backend
    port: 80
    protocol: http
    routes:
      - name: identity-route
        paths:
          - /NWC/rest/Login
          - /NWC/rest/NewSeg
          - /NWC/rest/identity/check
        strip_path: false
    plugins:
      - name: identity-matrix
        config:
          redis_host: ${REDIS_HOST}
          redis_port: 6379
          north_upstream: north-backend
          south_upstream: south-backend
          msisdn_header: "X-MSISDN"
          region_header: "X-Target-Region"

  - name: switch-svc
    host: north-backend
    port: 80
    protocol: http
    routes:
      - name: switch-route
        paths:
          - /switch/decision
          - /switch/authenticate
          - /switch/set-default
          - /switch/create
          - /NWC/rest/switch/decision
          - /NWC/rest/switch/authenticate
          - /NWC/rest/switch/set-default
          - /NWC/rest/register/second-account
        strip_path: false
    plugins:
      - name: switch-account
        config:
          redis_host: ${REDIS_HOST}
          redis_port: 6379
          redis_timeout: 1000
          passport_prefix: "passport:"
          msisdn_header: "X-MSISDN"
          device_id_header: "X-Device-Id"
          region_header: "X-Target-Region"
          north_upstream: north-backend
          south_upstream: south-backend
          strip_internal_names: true
          idempotency_ttl_seconds: 10
          audit_logging_enabled: true
