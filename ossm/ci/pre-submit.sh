#!/bin/bash

DIR=$(cd "$(dirname "$0")" ; pwd -P)

time cargo build --release --features tls-openssl --no-default-features"
