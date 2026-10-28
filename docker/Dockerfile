# ==============================================================================
# Custom Meilisearch Dockerfile with Enhanced Thai Charabia Tokenizer
# ==============================================================================
# Patches Meilisearch v1.56.0 with:
#   https://github.com/kamthorn/charabia (branch: thai-tcc-engine)
#
# Key Thai enhancements included:
#   1. Thai Character Cluster (TCC) R2 DFA Engine (56-state Moore-reduced DFA)
#   2. Sub-word / Base Morpheme dictionary (60,937 words, pruned long compounds)
#   3. Decomposed Sara Am normalization (U+0E4D + tone + U+0E32 -> U+0E33)
#   4. Zero-Width character filtering (U+200B, U+200C, U+200D, U+FEFF) without breaking words
#   5. Consecutive duplicate Thai combining mark deduplication
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Build Custom Meilisearch Binary
# ------------------------------------------------------------------------------
FROM rust:1.98.1-alpine3.24 AS builder

ARG MEILISEARCH_TAG=v1.56.0
ARG CHARABIA_REPO=https://github.com/kamthorn/charabia.git
ARG CHARABIA_BRANCH=thai-tcc-engine

RUN apk add --no-cache \
    git \
    build-base \
    musl-dev \
    openssl-dev \
    openssl-libs-static \
    pkgconfig \
    cmake \
    clang \
     clang-dev \
    llvm-dev \
    linux-headers \
    perl \
    python3 \
    curl \
    nodejs \
    npm \
    yarn

WORKDIR /src

# 1. Clone Meilisearch at the specified release tag
RUN git clone --depth 1 --branch ${MEILISEARCH_TAG} https://github.com/meilisearch/meilisearch.git .

# 2. Patch Cargo.toml to override charabia with the Thai-enhanced branch
RUN printf '\n[patch.crates-io]\ncharabia = { git = "%s", branch = "%s" }\n' \
    "${CHARABIA_REPO}" "${CHARABIA_BRANCH}" >> Cargo.toml

# 3. Update Cargo.lock to pull the patched charabia commit
RUN cargo update -p charabia

# 4. Compile release binaries (meilisearch & meilitool)
ENV CARGO_PROFILE_RELEASE_DEBUG=false
ENV OPENSSL_STATIC=1

RUN cargo build --release --bin meilisearch --bin meilitool && \
    strip target/release/meilisearch target/release/meilitool

# ------------------------------------------------------------------------------
# Stage 2: Minimal Production Runtime Image
# ------------------------------------------------------------------------------
FROM alpine:3.24

RUN apk add --no-cache \
    libgcc \
    libstdc++ \
    ca-certificates \
    curl \
    tini

ENV MEILI_HTTP_ADDR=0.0.0.0:7700
ENV MEILI_SERVER_PROVIDER=docker

WORKDIR /meili_data

COPY --from=builder /src/target/release/meilisearch /bin/meilisearch
COPY --from=builder /src/target/release/meilitool /bin/meilitool

RUN ln -s /bin/meilisearch /meilisearch

EXPOSE 7700

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/meilisearch"]
