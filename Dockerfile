FROM erlang:21.0.9-alpine as builder

RUN apk add --no-cache --update tar curl git bash make libc-dev gcc g++ vim

RUN set -xe \
    && curl -fSL -o rebar3 "https://s3.amazonaws.com/rebar3-nightly/rebar3" \
    && chmod +x ./rebar3 \
    && ./rebar3 local install \
    && rm ./rebar3

ENV PATH "$PATH:/root/.cache/rebar3/bin"

WORKDIR /usr/src/app

# build and cache dependencies
COPY rebar.config rebar.lock /usr/src/app/
RUN rebar3 compile

# copy in the vonnegut source and build release
COPY . /usr/src/app
RUN rebar3 as prod tar

RUN mkdir -p /opt/rel
RUN tar -zxvf /usr/src/app/_build/prod/rel/*/*.tar.gz -C /opt/rel

FROM alpine:3.8

RUN apk add --no-cache openssl-dev ncurses

WORKDIR /opt/vonnegut

ENV RELX_REPLACE_OS_VARS true
ENV NODE 127.0.0.1
ENV COOKIE vonnegut
ENV CHAIN_NAME chain1
ENV REPLICAS 1
ENV PEER_IP 127.0.0.1
ENV DISCOVERY_DOMAIN local

COPY --from=builder /opt/rel /opt/vonnegut

EXPOSE 5555 5555

ENTRYPOINT ["/opt/vonnegut/bin/vonnegut"]

CMD ["foreground"]
