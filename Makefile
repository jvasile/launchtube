.PHONY: build linux windows clean run dev

build: linux

linux:
	$(MAKE) -C launchtube-wails linux

windows:
	$(MAKE) -C launchtube-wails windows

dev:
	$(MAKE) -C launchtube-wails dev

run: linux
	./launchtube-wails/build/bin/launchtube-wails

clean:
	$(MAKE) -C launchtube-wails clean
