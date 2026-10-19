.PHONY: all build test clippy fmt check inspect clean

all: check test

build:
	cargo build --release --all-targets

test:
	cargo test --all-targets

clippy:
	cargo clippy --all-targets -- -D warnings

fmt:
	cargo fmt --all -- --check

check: fmt clippy

inspect:
	cargo run --quiet --bin qwave-inspect -- badge 0x8b15cafed00d0420 supporter 1760000000 1762678400 1760003600

clean:
	cargo clean
