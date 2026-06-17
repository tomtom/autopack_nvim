.PHONY: all test lint doc push pull

all: lint test

test:
	set -o pipefail; LUA_PATH="./lua/?.lua;./lua/?/init.lua;;" luajit tests/autopack_spec.lua $(if $(TEST),| grep -E "$(TEST)|^1\.\.|^#")

lint:
	luacheck lua/ tests/

doc:
	nvim --headless -c "helptags doc" -c "quit"

push:
	git push origin

pull:
	git pull origin
