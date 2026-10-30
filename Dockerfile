# Match the primary OTP/rebar3 versions used in .github/workflows/erlang.yml.
ARG OTP_VERSION=27.3.4.19
FROM erlang:${OTP_VERSION}

ARG REBAR3_VERSION=3.25.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 python3-httpbin gunicorn tini \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --location --retry 3 \
        "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
        --output /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3 \
    && rebar3 version

COPY docker/entrypoint.sh /usr/local/bin/hackney-test-entrypoint
RUN chmod +x /usr/local/bin/hackney-test-entrypoint

WORKDIR /workspace/hackney
COPY . .

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/hackney-test-entrypoint"]
CMD ["sh", "-ec", "rebar3 compile && rebar3 xref && rebar3 eunit && rebar3 dialyzer"]
