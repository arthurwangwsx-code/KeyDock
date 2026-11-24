.PHONY: doctor check build debug desktop-fixture package release publish verify-release install rollback
doctor:
	python3 scripts/keydock.py doctor
check:
	python3 scripts/keydock.py check
build:
	python3 scripts/keydock.py build --profile preview --allow-dirty
debug:
	python3 scripts/keydock.py debug
desktop-fixture:
	python3 scripts/keydock.py desktop-fixture
package:
	python3 scripts/keydock.py package
release:
	python3 scripts/keydock.py release
publish:
	python3 scripts/keydock.py publish
verify-release:
	python3 scripts/keydock.py verify-release
install:
	python3 scripts/keydock.py install-release
rollback:
	python3 scripts/keydock.py rollback "$(RECEIPT)" --quit-running
