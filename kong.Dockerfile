# Kong gateway + gettext-base (envsubst) so the kong service in docker-compose.yml
# can expand the ${TOKEN}s in kong.yml.tpl from docker env vars at container start.
# Everything else is the stock kong:3.8 image.
FROM kong:3.8
USER root
RUN apt-get update && apt-get install -y --no-install-recommends gettext-base && rm -rf /var/lib/apt/lists/*
USER kong