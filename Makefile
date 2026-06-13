.PHONY: test test_file deps core core_test

# Build the native sidecar binary and install it where the plugin looks for it.
core:
	cd rust && cargo build --release
	@mkdir -p bin
	cp rust/target/release/dired-core bin/dired-core

core_test:
	cd rust && cargo test

# Run all tests: make test (Lua suite; does not need the native binary)
test: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua MiniTest.run()"

# Run a single file: make test_file FILE=tests/test_fs.lua
test_file: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('$(FILE)')"

deps: deps/mini.nvim
deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@
