# 
# build illa-builder-frontend
#

FROM node:18-bullseye as illa-builder-frontend

ARG VITE_API_BASE_URL="" \
    VITE_CLOUD_URL=""

## clone frontend
WORKDIR /opt/illa/illa-builder-frontend
RUN cd /opt/illa/illa-builder-frontend
RUN pwd

ARG FE=main
RUN git clone -b ${FE} https://github.com/illacloud/illa-builder.git /opt/illa/illa-builder-frontend/
RUN git submodule init; \
    git submodule update; \
    cat apps/builder/.env.self 1>&2; \
    echo ; \
    echo "VITE_INSTANCE_ID=CLOUD\nVITE_API_BASE_URL=${VITE_API_BASE_URL}\nVITE_CLOUD_URL=${VITE_CLOUD_URL}\nVITE_SENTRY_SERVER_API=\nILLA_SENTRY_AUTH_TOKEN=\nILLA_APP_VERSION=0.0.0\nILLA_APP_ENV=production\nILLA_GOOGLE_MAP_KEY=\nILLA_MIXPANEL_API_KEY=\n" > apps/builder/.env.self; \
    cat apps/builder/.env.self 1>&2;

RUN npm install -g pnpm
RUN whereis pnpm && whereis node

RUN pnpm install
RUN pnpm build-self


# 
# build illa-builder-backend & illa-builder-backend-ws
#

FROM golang:1.19-bullseye as illa-builder-backend

## set env
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

## build
WORKDIR /opt/illa/illa-builder-backend
RUN cd  /opt/illa/illa-builder-backend
RUN ls -alh

ARG BE=main
RUN git clone -b ${BE} https://github.com/illacloud/builder-backend.git ./

RUN cat ./Makefile

RUN make all 

RUN ls -alh ./bin/* 


#
# build illa-supervisor-backend & illa-supervisor-backend-internal
#

FROM golang:1.19-bullseye as illa-supervisor-backend

## set env
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

## build
WORKDIR /opt/illa/illa-supervisor-backend
RUN cd  /opt/illa/illa-supervisor-backend
RUN ls -alh

ARG SBE=main
RUN git clone -b ${SBE} https://github.com/illacloud/illa-supervisor-backend.git ./

RUN cat ./Makefile

RUN make all 

RUN ls -alh ./bin/*


#
# build nginx
#
FROM nginx:1.24-bullseye as webserver-nginx

RUN ls -alh /usr/sbin/nginx; ls -alh /usr/lib/nginx; ls -alh /etc/nginx; ls -alh /usr/share/nginx;

#
# build envoy
#
FROM envoyproxy/envoy:v1.18.2 as ingress-envoy

RUN ls -alh /etc/envoy

RUN ls -alh /usr/local/bin/envoy* 
RUN ls -alh /usr/local/bin/su-exec 
RUN ls -alh /etc/envoy/envoy.yaml
RUN ls -alh  /docker-entrypoint.sh 


# 
# Assembly all-in-one image
#
FROM debian:11-slim as runner

#
# init environment & install required debug & runtime tools
#
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    netbase \
    wget \
    telnet \
    gnupg \
    dirmngr \
    dumb-init \
    procps \
    iproute2 \
    gettext-base \
    postgresql-client \
    gosu \
    gettext \
    ; \
    rm -rf /var/lib/apt/lists/*

# 
# init working folder and users
#
RUN mkdir /opt/illa
RUN addgroup --system --gid 102 nginx \
    && adduser --system --disabled-login --ingroup nginx --no-create-home --home /nonexistent --gecos "nginx user" --shell /bin/false --uid 102 nginx \
    && adduser --group --system envoy \
    && adduser --group --system minio \
    && adduser --group --system redis \
    && adduser --group --system illa \
    && cat /etc/group 

#
# copy illa-builder-backend bin
#
COPY --from=illa-builder-backend /opt/illa/illa-builder-backend /opt/illa/illa-builder-backend

#
# copy illa-supervisor-backend bin
#
COPY --from=illa-supervisor-backend /opt/illa/illa-supervisor-backend /opt/illa/illa-supervisor-backend

#
# copy illa-builder-frontend
#
COPY --from=illa-builder-frontend /opt/illa/illa-builder-frontend/apps/builder/dist/index.html /opt/illa/illa-builder-frontend/index.html
COPY --from=illa-builder-frontend /opt/illa/illa-builder-frontend/apps/builder/dist/assets /opt/illa/illa-builder-frontend/assets

#
# copy gosu
#

RUN gosu --version; \
	gosu nobody true

#
# copy nginx
#
RUN mkdir /opt/illa/nginx

COPY --from=webserver-nginx /usr/sbin/nginx  /usr/sbin/nginx 
COPY --from=webserver-nginx /usr/lib/nginx   /usr/lib/nginx 
COPY --from=webserver-nginx /etc/nginx       /etc/nginx 
COPY --from=webserver-nginx /usr/share/nginx /usr/share/nginx 

COPY config/nginx/nginx.conf /etc/nginx/nginx.conf
COPY config/nginx/illa-builder-frontend.conf /etc/nginx/conf.d/
COPY scripts/nginx-entrypoint.sh /opt/illa/nginx

RUN set -x \
    && mkdir /var/log/nginx/ \
    && chmod 0777 /var/log/nginx/ \
    && mkdir /var/cache/nginx/ \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && touch /tmp/nginx.pid \
    && chmod 0777 /tmp/nginx.pid \
    && rm /etc/nginx/conf.d/default.conf \
    && chmod +x /opt/illa/nginx/nginx-entrypoint.sh \
    && chown -R $UID:0 /var/cache/nginx \
    && chmod -R g+w /var/cache/nginx \
    && chown -R $UID:0 /etc/nginx \
    && chmod -R g+w /etc/nginx

#RUN nginx -t


#
# copy envoy
#
ENV ENVOY_UID 0 # set to root for envoy listing on 80 prot
ENV ENVOY_GID 0

RUN mkdir -p /opt/illa/envoy \
    && mkdir -p /etc/envoy

COPY --from=ingress-envoy  /usr/local/bin/envoy* /usr/local/bin/
COPY --from=ingress-envoy  /usr/local/bin/su-exec  /usr/local/bin/
COPY --from=ingress-envoy  /etc/envoy/envoy.yaml  /etc/envoy/

COPY config/envoy/illa-unit-ingress.yaml /opt/illa/envoy
COPY scripts/envoy-entrypoint.sh /opt/illa/envoy

RUN chmod +x /opt/illa/envoy/envoy-entrypoint.sh \
    && ls -alh /usr/local/bin/envoy* \
    && ls -alh /usr/local/bin/su-exec \
    && ls -alh /etc/envoy/envoy.yaml

#
# init database 
#
RUN mkdir -p /opt/illa/database/ \
    && mkdir -p /opt/illa/postgres/

COPY scripts/postgres-entrypoint.sh  /opt/illa/postgres
COPY scripts/postgres-init-external.sh /opt/illa/postgres
RUN chmod +x /opt/illa/postgres/postgres-entrypoint.sh \
    && chmod +x /opt/illa/postgres/postgres-init-external.sh 


#
# add main scripts
#
COPY scripts/main-external.sh /opt/illa/
COPY scripts/pre-init.sh /opt/illa/
COPY scripts/post-init-external.sh /opt/illa/
RUN chmod +x /opt/illa/main-external.sh 
RUN chmod +x /opt/illa/pre-init.sh 
RUN chmod +x /opt/illa/post-init-external.sh 

#
# modify global permission
#  
COPY config/system/group /opt/illa/
RUN cat /opt/illa/group > /etc/group; rm /opt/illa/group
RUN chown -fR illa:root /opt/illa
RUN chmod 775 -fR /opt/illa

ENV ILLA_SERVER_HOST="0.0.0.0" \
    #ILLA_SERVER_PORT="8001" \
    #ILLA_SERVER_INTERNAL_PORT="9001" \
    ILLA_SERVER_MODE="debug" \
    ILLA_DEPLOY_MODE="cloud-test" \
    ILLA_PG_ADDR="localhost" \
    ILLA_PG_PORT="5432" \
    ILLA_PG_USER="illa_builder" \
    ILLA_PG_PASSWORD="71De5JllWSetLYU" \
    ILLA_PG_DATABASE="illa_builder" \
    ILLA_REDIS_ADDR="localhost" \
    ILLA_REDIS_PORT="6379" \
    ILLA_REDIS_PASSWORD="illa2022" \
    ILLA_REDIS_DATABASE="0" \
    ILLA_DRIVE_TYPE="" \
    ILLA_DRIVE_ACCESS_KEY_ID="" \
    ILLA_DRIVE_ACCESS_KEY_SECRET="" \
    ILLA_DRIVE_REGION="" \
    ILLA_DRIVE_ENDPOINT="127.0.0.1:9000" \
    ILLA_DRIVE_HOST="127.0.0.1" \
    ILLA_DRIVE_SYSTEM_BUCKET_NAME="illa-cloud" \
    ILLA_DRIVE_TEAM_BUCKET_NAME="illa-cloud-team" \
    ILLA_DRIVE_UPLOAD_TIMEOUT="30s" \
    ILLA_CONTROL_TOKEN=""

#
# run
#
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
EXPOSE 8000
CMD ["/opt/illa/main-external.sh"]
