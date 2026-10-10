FROM haproxy:3.3.15-alpine
USER root
RUN apk add --no-cache iproute2
ENTRYPOINT []
