#!/usr/bin/env sh
set -e

loglevel="${loglevel:-}"
USERID=$(id -u)


# if the first argument look like a parameter (i.e. start with '-'), run Envoy
if [ "${1#-}" != "$1" ]; then
    set -- envoy "$@"
fi

if [ "$1" = 'envoy' ]; then
    # set the log level if the $loglevel variable is set
    if [ -n "$loglevel" ]; then
        set -- "$@" --log-level "$loglevel"
    fi
fi

cp  /opt/illa/envoy/illa-unit-ingress.yaml /opt/illa/envoy/illa-unit-ingress.yaml.template
cat /opt/illa/envoy/illa-unit-ingress.yaml.template | envsubst \$ILLA_DRIVE_HOST,\$ILLA_DRIVE_ENDPOINT > /opt/illa/envoy/illa-unit-ingress.yaml

if [ "$ENVOY_UID" != "0" ] && [ "$USERID" = 0 ]; then
    if [ -n "$ENVOY_UID" ]; then
        usermod -u "$ENVOY_UID" envoy
    fi
    if [ -n "$ENVOY_GID" ]; then
        groupmod -g "$ENVOY_GID" envoy
    fi
    # Ensure the envoy user is able to write to container logs
    chown envoy:envoy /dev/stdout /dev/stderr
    exec su-exec envoy "${@}"
else
    exec "${@}"
fi
