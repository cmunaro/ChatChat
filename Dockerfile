# syntax=docker/dockerfile:1

ARG BUILDER_IMAGE
FROM ${BUILDER_IMAGE} AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git libsctp1 \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /build

COPY mix.exs mix.lock ./
COPY config config
COPY apps apps

RUN mix deps.get --only prod
RUN mix compile

ARG RELEASE_NAME
RUN test -n "$RELEASE_NAME" \
    && mix release "$RELEASE_NAME" \
    && mv "_build/prod/rel/$RELEASE_NAME" /release \
    && ln -s "$RELEASE_NAME" /release/bin/server

FROM busybox:1.37.0-musl AS busybox

FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

WORKDIR /app
COPY --from=busybox /bin /bin
COPY --from=build /lib/*-linux-gnu/libtinfo.so.6* /usr/lib/
COPY --from=build /lib/*-linux-gnu/libsctp.so.1* /usr/lib/
COPY --from=build --chown=nonroot:nonroot /release ./

USER nonroot

ENV HOME=/tmp
ENV LANG=C.UTF-8
ENV LD_LIBRARY_PATH=/usr/lib
ENV ELIXIR_ERL_OPTIONS=+fnu

EXPOSE 4000 4040

ENTRYPOINT ["/app/bin/server"]
CMD ["start"]
