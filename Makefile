.PHONY: test test_file deps

# Run all tests: make test
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
