REBAR = $(shell pwd)/rebar3
.PHONY: rel test relgentlerain

all: compile

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

distclean: clean relclean
	$(REBAR) clean --all

cleantests:
	rm -f test/utils/*.beam
	rm -f test/singledc/*.beam
	rm -f test/multidc/*.beam
	rm -rf logs/

shell: rel
	export NODE_NAME=antidote@127.0.0.1 ; \
	export COOKIE=antidote ; \
	export ROOT_DIR_PREFIX=$$NODE_NAME/ ; \
	_build/default/rel/antidote/bin/antidote console

rel:
	$(REBAR) release

relclean:
	rm -rf _build/default/rel

reltest: rel
	test/release_test.sh

# style checks
lint:
	${REBAR} as lint lint

check: distclean cleantests test reltest dialyzer lint

relgentlerain: export TXN_PROTOCOL=gentlerain
relgentlerain: relclean cleantests rel

relnocert: export NO_CERTIFICATION=true
relnocert: relclean cleantests rel

stage :
	$(REBAR) release -d

compile-utils: compile
	for filename in "test/utils/*.erl" ; do \
		erlc -o test/utils $$filename ; \
	done

test:
	${REBAR} eunit skip_deps=true

coverage:
	${REBAR} cover --verbose

singledc: compile-utils rel
	rm -f test/singledc/*.beam
	mkdir -p logs
ifdef SUITE
	ct_run -pa ./_build/default/lib/*/ebin test/utils/ -logdir logs -suite test/singledc/${SUITE} -cover test/antidote.coverspec
else
	ct_run -pa ./_build/default/lib/*/ebin test/utils/ -logdir logs -dir test/singledc -cover test/antidote.coverspec
endif

multidc: compile-utils rel
	rm -f test/multidc/*.beam
	mkdir -p logs
ifdef SUITE
	ct_run -pa ./_build/default/lib/*/ebin test/utils/ -logdir logs -suite test/multidc/${SUITE} -cover test/antidote.coverspec
else
	ct_run -pa ./_build/default/lib/*/ebin test/utils/ -logdir logs -dir test/multidc -cover test/antidote.coverspec
endif

systests: singledc multidc

docs:
	${REBAR} doc skip_deps=true

xref: compile
	${REBAR} xref skip_deps=true

dialyzer:
	${REBAR} dialyzer

docker-build:
	DOCKERTMPDIR="$(shell mktemp -d ./docker-tmpdir.XXXXXXXX)" ; \
	wget "https://raw.githubusercontent.com/AntidoteDB/docker-antidote/master/local-build/Dockerfile" -O "$$DOCKERTMPDIR/Dockerfile" ; \
    wget "https://raw.githubusercontent.com/AntidoteDB/docker-antidote/master/local-build/entrypoint.sh" -O "$$DOCKERTMPDIR/entrypoint.sh" ; \
    wget "https://raw.githubusercontent.com/AntidoteDB/docker-antidote/master/local-build/start_and_attach.sh" -O "$$DOCKERTMPDIR/start_and_attach.sh" ; \
    docker build -f $$DOCKERTMPDIR/Dockerfile --build-arg DOCKERFILES=$$DOCKERTMPDIR -t antidotedb:local-build . ; \
    [ ! -d $$DOCKERTMPDIR ] || rm -r $$DOCKERTMPDIR

docker-run: docker-build
	docker run -d --name antidote -p "8087:8087" antidotedb:local-build

docker-clean:
ifneq ($(docker images -q antidotedb:local-build 2> /dev/null), "")
	docker image rm -f antidotedb:local-build
endif
	[ ! -d docker-tmpdir* ] || rm -r docker-tmpdir*
