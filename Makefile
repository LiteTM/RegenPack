# Build the package. Uses VESC Tool when available, else the bundled packer.
PKG  := regen_settings
OUT  := dist/regen_settings.vescpkg

all: $(OUT)

$(OUT): $(PKG)/pkgdesc.qml $(PKG)/regen.lisp $(PKG)/ui.qml $(PKG)/README.md tools/build_vescpkg.py
	@mkdir -p dist
	@if command -v vesc_tool >/dev/null 2>&1; then \
		cd $(PKG) && vesc_tool --buildPkg "../$(OUT):pkgdesc.qml"; \
	else \
		python3 tools/build_vescpkg.py build $(PKG)/pkgdesc.qml -o $(OUT); \
	fi

verify: $(OUT)
	python3 tools/build_vescpkg.py verify $(OUT)

clean:
	rm -f $(OUT)

.PHONY: all verify clean
