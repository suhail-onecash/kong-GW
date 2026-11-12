# Base for the kong template render one-shot (docker-compose.yml, service "render").
# Tools are installed at build time so renders never need the network at run time.
FROM alpine:3.20
RUN apk add --no-cache jq gettext
