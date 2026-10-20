.PHONY: build app run stop install test check-config clean

build:
	swift build

app:
	./scripts/build-app.sh

# Build and (re)start Oz from build/Oz.app
run: app stop
	open build/Oz.app

stop:
	-pkill -x OzWM

# Copy to ~/Applications (open it from there to grant Accessibility once)
install: app stop
	mkdir -p ~/Applications
	rm -rf ~/Applications/Oz.app
	cp -R build/Oz.app ~/Applications/Oz.app
	open ~/Applications/Oz.app

test:
	swift test

check-config: build
	.build/debug/OzWM --check-config

clean:
	rm -rf .build build
