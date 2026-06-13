.PHONY: test test_file deps core core_test

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	CORE_LIB := rust/target/release/libdired_core.dylib
else
	CORE_LIB := rust/target/release/libdired_core.so
endif

# Build the optional Rust core and install it where nvim's require() finds it
core:
	cargo build --release --manifest-path rust/Cargo.toml
	cp $(CORE_LIB) lua/dired_core.so

core_test:
	cargo test --manifest-path rust/Cargo.toml

# Run all tests: make test
test: deps/mini.nvim core
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua MiniTest.run()"

# Run a single file: make test_file FILE=tests/test_fs.lua
test_file: deps/mini.nvim core
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('$(FILE)')"

deps: deps/mini.nvim
deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@
