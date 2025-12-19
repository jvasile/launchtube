.PHONY: build linux windows clean run dev install

build: linux

linux:
	$(MAKE) -C app linux

windows:
	$(MAKE) -C app windows

dev:
	$(MAKE) -C app dev

run: linux
	./app/build/bin/launchtube

clean:
	$(MAKE) -C app clean

install:
	$(MAKE) -C app install
