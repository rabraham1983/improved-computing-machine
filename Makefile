.PHONY: build run test app clean

build:
	swift build

run:
	swift run CodeScope

test:
	swift test

app:
	Scripts/build-app.sh

clean:
	rm -rf .build build
