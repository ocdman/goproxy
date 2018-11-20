#!/bin/bash -xe

export GITHUB_USER=${GITHUB_USER:-ocdman}
export GITHUB_EMAIL=${GITHUB_EMAIL:-ocdman2@gmail.com}
export GITHUB_REPO=${GITHUB_REPO:-goproxy}
export GITHUB_CI_REPO=${GITHUB_CI_REPO:-goproxy-ci}
export GITHUB_COMMIT_ID=${TRAVIS_COMMIT:-${COMMIT_ID:-master}}
export SOURCEFORGE_USER=${SOURCEFORGE_USER:-${GITHUB_USER}}
export SOURCEFORGE_REPO=${SOURCEFORGE_REPO:-${GITHUB_REPO}}
export WORKING_DIR=$(pwd)/${GITHUB_REPO}.${RANDOM:-$$}
export GOROOT_BOOTSTRAP=${WORKING_DIR}/goroot_bootstrap
export GOROOT=${WORKING_DIR}/go
export GOPATH=${WORKING_DIR}/gopath
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export GOTIP_FOLLOW=${GOTIP_FOLLOW:-true}

if [ ${#GITHUB_TOKEN} -eq 0 ]; then
	echo "WARNING: \$GITHUB_TOKEN is not set!"
fi

if [ ${#SOURCEFORGE_PASSWORD} -eq 0 ]; then
	echo "WARNING: \$SOURCEFORGE_PASSWORD is not set!"
fi

for CMD in curl awk git tar bzip2 xz 7za gcc sha1sum timeout grep
do
	if ! type -p ${CMD}; then
		echo -e "\e[1;31mtool ${CMD} is not installed, abort.\e[0m"
		exit 1
	fi
done

mkdir -p ${WORKING_DIR}

function rename() {
	for FILENAME in ${@:2}
	do
		local NEWNAME=$(echo ${FILENAME} | sed -r $1)
		if [ "${NEWNAME}" != "${FILENAME}" ]; then
			mv -f ${FILENAME} ${NEWNAME}
		fi
	done
}

function init_github() {
	pushd ${WORKING_DIR}

	git config --global user.name "${GITHUB_USER}"
	git config --global user.email "${GITHUB_EMAIL}"

	if ! grep -q 'machine github.com' ~/.netrc; then
		if [ ${#GITHUB_TOKEN} -gt 0 ]; then
			(set +x; echo "machine github.com login $GITHUB_USER password $GITHUB_TOKEN" >>~/.netrc)
		fi
	fi

	popd
}

function build_go() {
	pushd ${WORKING_DIR}

	curl -k https://storage.googleapis.com/golang/go1.4.3.linux-amd64.tar.gz | tar xz
	mv go goroot_bootstrap

	git clone --branch master https://github.com/ocdman/go
	cd go/src
	if [ "${GOTIP_FOLLOW}" = "true" ]; then
		git remote add -f upstream https://github.com/golang/go
		git rebase upstream/master
	fi
	bash ./make.bash
	grep -q 'machine github.com' ~/.netrc && git push -f origin master

	set +ex
	echo '================================================================================'
	cat /etc/issue
	uname -a
	lscpu
	echo
	go version
	go env
	echo
	env | grep -v GITHUB_TOKEN | grep -v SOURCEFORGE_PASSWORD
	echo '================================================================================'
	set -ex

	popd
}

function build_glog() {
	pushd ${WORKING_DIR}

	git clone https://github.com/ocdman/glog $GOPATH/src/github.com/ocdman/glog
	cd $GOPATH/src/github.com/ocdman/glog
	git remote add -f upstream https://github.com/golang/glog
	git rebase upstream/master
	go build -v
	grep -q 'machine github.com' ~/.netrc && git push -f origin master

	popd
}

function build_http2() {
	pushd ${WORKING_DIR}

	git clone https://github.com/ocdman/net $GOPATH/src/github.com/ocdman/net
	cd $GOPATH/src/github.com/ocdman/net/http2
	git remote add -f upstream https://github.com/golang/net
	git rebase upstream/master
	go get -x github.com/ocdman/net/http2
	grep -q 'machine github.com' ~/.netrc && git push -f origin master

	popd
}

function build_bogo() {
	pushd ${WORKING_DIR}

	git clone https://github.com/google/boringssl $GOPATH/src/github.com/google/boringssl
	cd $GOPATH/src/github.com/google/boringssl/ssl/test/runner
	sed -i -E 's#"./(curve25519|poly1305)"#"golang.org/x/crypto/\1"#g' *.go
	sed -i -E 's#"./(ed25519)"#"github.com/google/boringssl/ssl/test/runner/\1"#g' *.go
	sed -i -E 's#"./(internal/edwards25519)"#"github.com/google/boringssl/ssl/test/runner/ed25519/\1"#g' ed25519/*.go
	git commit -m "change imports" -s -a
	go get -x github.com/google/boringssl/ssl/test/runner

	popd
}

function build_quicgo() {
	pushd ${WORKING_DIR}

	git clone https://github.com/ocdman/quic-go $GOPATH/src/github.com/ocdman/quic-go
	cd $GOPATH/src/github.com/ocdman/quic-go
	git remote add -f upstream https://github.com/lucas-clemente/quic-go
	git rebase upstream/master
	go get -v github.com/ocdman/quic-go/h2quic
	grep -q 'machine github.com' ~/.netrc && git push -f origin master

	popd
}

function build_goproxy() {
	pushd ${WORKING_DIR}

	git clone https://github.com/${GITHUB_USER}/gop ${GITHUB_REPO}
	cd ${GITHUB_REPO}

	if [ ${TRAVIS_PULL_REQUEST:-false} == "false" ]; then
		git checkout -f ${GITHUB_COMMIT_ID}
	else
		git fetch origin pull/${TRAVIS_PULL_REQUEST}/head:pr
		git checkout -f pr
	fi

	export RELEASE=$(git rev-list --count HEAD)
	export RELEASE_DESCRIPTION=$(git log -1 --oneline --format="r${RELEASE}: [\`%h\`](https://github.com/${GITHUB_USER}/goproxy/commit/%h) %s")
	if [ -n "${TRAVIS_BUILD_ID}" ]; then
		export RELEASE_DESCRIPTION=$(echo ${RELEASE_DESCRIPTION} | sed -E "s#^(r[0-9]+)#[\1](https://travis-ci.org/${GITHUB_USER}/${GITHUB_REPO}/builds/${TRAVIS_BUILD_ID})#g")
	fi

	if grep -lr $(printf '\r\n') * | grep '.go$' ; then
		echo -e "\e[1;31mPlease run dos2unix for go source files\e[0m"
		exit 1
	fi

	if [ "$(gofmt -l . | tee /dev/tty)" != "" ]; then
		echo -e "\e[1;31mPlease run 'gofmt -s -w .' for go source files\e[0m"
		exit 1
	fi

	awk 'match($1, /"((github\.com|golang\.org|gopkg\.in)\/.+)"/) {if (!seen[$1]++) {gsub("\"", "", $1); print $1}}' $(find . -name "*.go") | xargs -n1 -i go get -u -v {}

	go test -v ./httpproxy/helpers

	pushd ./assets/taskbar
	env GOARCH=amd64 ./make.bash
	env GOARCH=386 ./make.bash
	popd

	cat <<EOF |
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 ./make.bash
GOOS=freebsd GOARCH=386 CGO_ENABLED=0 ./make.bash
GOOS=freebsd GOARCH=amd64 CGO_ENABLED=0 ./make.bash
GOOS=freebsd GOARCH=arm CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=386 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=arm CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=arm CGO_ENABLED=1 ./make.bash
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=mips CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=mips64 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=mips64le CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=mipsle CGO_ENABLED=0 ./make.bash
GOOS=windows GOARCH=386 CGO_ENABLED=0 ./make.bash
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 ./make.bash
EOF
	xargs --max-procs=5 -n1 -i bash -c {}

	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 ./make.bash check

	mkdir -p ${WORKING_DIR}/r${RELEASE}
	cp -r build/*/dist/* ${WORKING_DIR}/r${RELEASE}

	git archive --format=tar --prefix="goproxy-r${RELEASE}/" HEAD | xz > "${WORKING_DIR}/r${RELEASE}/source.tar.xz"

	cd ${WORKING_DIR}/r${RELEASE}
	rename 's/_darwin_(amd64|386)/_macos_\1/' *
	rename 's/_darwin_(arm64|arm)/_ios_\1/' *

	mkdir -p GoProxy.app/Contents/{MacOS,Resources}
	tar xvpf goproxy_macos_amd64-r${RELEASE}.tar.bz2 -C GoProxy.app/Contents/MacOS/
	cp ${WORKING_DIR}/${GITHUB_REPO}/assets/packaging/goproxy-macos.icns GoProxy.app/Contents/Resources/
	cat <<EOF > GoProxy.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
        <key>CFBundleExecutable</key>
        <string>goproxy-macos</string>
        <key>CFBundleGetInfoString</key>
        <string>GoProxy For macOS</string>
        <key>CFBundleIconFile</key>
        <string>goproxy-macos</string>
        <key>CFBundleName</key>
        <string>GoProxy</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
</dict>
</plist>
EOF
	cat <<EOF > GoProxy.app/Contents/MacOS/goproxy-macos
#!$(head -1 GoProxy.app/Contents/MacOS/goproxy-macos.command | tr -d '()' | awk '{print $1}')
import os
__file__ = os.path.join(os.path.dirname(__file__), 'goproxy-macos.command')
exec compile(open(__file__, 'rb').read().split('\n', 1)[1], __file__, 'exec')
EOF
	chmod +x GoProxy.app/Contents/MacOS/goproxy-macos
	export GAE_MACOS_REVSION=$(cd ${WORKING_DIR}/${GITHUB_REPO} && git log --oneline -- assets/packaging/goproxy-macos.command | wc -l | xargs)
	sed -i "s/r9999/r${GAE_MACOS_REVSION}/" GoProxy.app/Contents/MacOS/goproxy-macos.command
	BZIP=-9 tar cvjpf goproxy_macos_app-r${RELEASE}.tar.bz2 GoProxy.app
	rm -rf GoProxy.app

	for FILE in goproxy_windows_*.7z
	do
		cat ${WORKING_DIR}/${GITHUB_REPO}/assets/packaging/7zCon.sfx ${FILE} >${FILE}.exe
		/bin/mv ${FILE}.exe ${FILE}
	done

	ls -lht

	popd
}

function build_goproxy_gae() {
	pushd ${WORKING_DIR}/${GITHUB_REPO}

	git checkout -f server.gae
	git fetch origin server.gae
	git reset --hard origin/server.gae
	git clean -dfx .

	for FILE in python27.exe python27.dll python27.zip
	do
		curl -LOJ https://raw.githubusercontent.com/ocdman/pybuild/master/${FILE}
	done

	echo -e '@echo off\n"%~dp0python27.exe" uploader.py || pause' >uploader.bat

	export GAE_RELEASE=$(git rev-list --count HEAD)
	sed -i "s/r9999/r${GAE_RELEASE}/" gae/gae.go
	tar cvJpf ${WORKING_DIR}/r${RELEASE}/goproxy-gae-r${GAE_RELEASE}.tar.xz *

	popd
}

function build_goproxy_vps() {
	pushd ${WORKING_DIR}/${GITHUB_REPO}

	git checkout -f server.vps
	git fetch origin server.vps
	git reset --hard origin/server.vps
	git clean -dfx .

	git clone --branch master https://github.com/ocdman/goproxy $GOPATH/src/github.com/ocdman/goproxy
	awk 'match($1, /"((github\.com|golang\.org|gopkg\.in)\/.+)"/) {if (!seen[$1]++) {gsub("\"", "", $1); print $1}}' $(find . -name "*.go") | xargs -n1 -i go get -u -v {}

	cat <<EOF |
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=386 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=arm CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 ./make.bash
GOOS=linux GOARCH=mipsle CGO_ENABLED=0 ./make.bash
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 ./make.bash
GOOS=windows GOARCH=386 CGO_ENABLED=0 ./make.bash
EOF
	xargs --max-procs=5 -n1 -i bash -c {}

	local files=$(find ./build -type f -name "*.gz" -or -name "*.bz2" -or -name "*.xz" -or -name "*.7z")
	cp ${files} ${WORKING_DIR}/r${RELEASE}

	cd ${WORKING_DIR}/r${RELEASE}
	rename 's/_darwin_(amd64|386)/_macos_\1/' *

	popd
}

function release_github() {
	pushd ${WORKING_DIR}

	if [ ${#GITHUB_TOKEN} -eq 0 ]; then
		echo -e "\e[1;31m\$GITHUB_TOKEN is not set, abort\e[0m"
		exit 1
	fi

	git clone --branch "master" https://github.com/${GITHUB_USER}/${GITHUB_CI_REPO} ${GITHUB_CI_REPO}
	cd ${GITHUB_CI_REPO}

	git commit --allow-empty -m "release"
	git tag -d r${RELEASE} || true
	git tag r${RELEASE}
	git push -f origin r${RELEASE}

	cd ${WORKING_DIR}
	local GITHUB_RELEASE_URL=https://github.com/aktau/github-release/releases/download/v0.6.2/linux-amd64-github-release.tar.bz2
	local GITHUB_RELEASE_BIN=$(pwd)/$(curl -L ${GITHUB_RELEASE_URL} | tar xjpv | head -1)

	cd ${WORKING_DIR}/r${RELEASE}/

	for i in $(seq 5)
	do
		if ! ${GITHUB_RELEASE_BIN} release --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} --name "${GITHUB_REPO} r${RELEASE}" --description "${RELEASE_DESCRIPTION}" ; then
			sleep 3
			${GITHUB_RELEASE_BIN} delete --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} >/dev/null 2>&1 || true
			sleep 3
			continue
		fi

		local allok="true"
		for FILE in *
		do
			if ! timeout -k60 60 ${GITHUB_RELEASE_BIN} upload --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} --name ${FILE} --file ${FILE} ; then
				allok="false"
				break
			fi
		done
		if [ "${allok}" == "true" ]; then
			break
		fi
	done

	local files=$(ls ${WORKING_DIR}/r${RELEASE}/ | wc -l)
	local uploads=$(${GITHUB_RELEASE_BIN} info --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} | grep -- '- artifact: ' | wc -l)
	test ${files} -eq ${uploads}

	popd
}

function release_sourceforge() {
	pushd ${WORKING_DIR}/

	if [ ${#SOURCEFORGE_PASSWORD} -eq 0 ]; then
		echo -e "\e[1;31m\$SOURCEFORGE_PASSWORD is not set, abort\e[0m"
		exit 1
	fi

	set +ex

	for i in $(seq 5)
	do
		echo Uploading r${RELEASE}/* to https://sourceforge.net/projects/goproxy/files/r${RELEASE}/
		if timeout -k60 60 lftp "sftp://${SOURCEFORGE_USER}:${SOURCEFORGE_PASSWORD}@frs.sourceforge.net/home/frs/project/${SOURCEFORGE_REPO}/" -e "rm -rf r${RELEASE}; mkdir r${RELEASE}; mirror -R r${RELEASE} r${RELEASE}; bye"; then
			break
		fi
	done

	set -ex

	popd
}

function clean() {
	set +ex

	pushd ${WORKING_DIR}/r${RELEASE}/
	ls -lht
	echo
	echo 'sha1sum *'
	sha1sum * | xargs -n1 -i echo -e "\e[1;32m{}\e[0m"
	popd >/dev/null
	rm -rf ${WORKING_DIR}

	set -ex
}

init_github
build_go
build_glog
build_http2
build_bogo
build_quicgo
build_goproxy
if [ "x${TRAVIS_EVENT_TYPE}" == "xpush" ]; then
	build_goproxy_gae
	build_goproxy_vps
	release_github
	release_sourceforge
	clean
fi
