#!/usr/bin/env bash

# exit immediately on failure
set -e

if [ $# -lt 2 ]; then
    echo "Syntax: $0 <repo-relative/path/to/executable/> <windows|darwin|linux>"
    exit 1
fi

TOOLS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT_DIR=$(dirname $TOOLS_DIR)

if [ -z "$GOPATH" -o -z "$(which go)" ]; then
  echo "Missing GOPATH environment variable or 'go' executable. Please configure a Go build environment."
  exit 1
fi

REPO_NAME=dcos-commons # CI dir does not match repo name
GOPATH_MESOSPHERE="$GOPATH/src/github.com/mesosphere"
GOPATH_EXE_DIR="$GOPATH_MESOSPHERE/$REPO_NAME/$1"
if [ $2 = "windows" ]; then
    EXE_FILENAME=$(basename $1).exe
else
    EXE_FILENAME=$(basename $1)-$2
fi

# Detect Go version to determine:
# - if UPX should be used to compress binaries (Go 1.7+)
# - if vendoring needs to be manually enabled (Go 1.5)
GO_VERSION=$(go version | awk '{print $3}')
UPX_BINARY="" # only enabled for go1.7+
case "$GO_VERSION" in
    go1.[7-9]*|go1.1[0-9]*|go[2-9]*) # go1.7+, go2+ (must come before go1.0-go1.4: support e.g. go1.10)
        UPX_BINARY="$(which upx || which upx-ucl || echo '')" # avoid error code if upx isn't installed
        ;;
    go0.*|go1.[0-4]*) # go0.*, go1.0-go1.4
        echo "Detected Go <=1.4. This is too old, please install Go 1.5+: $(which go) $GO_VERSION"
        exit 1
        ;;
    go1.5*) # go1.5
        export GO15VENDOREXPERIMENT=1
        ;;
    go1.6*) # go1.6
        # no experiment, but also no UPX
        ;;
    *) # ???
        echo "Unrecognized go version: $(which go) $GO_VERSION"
        exit 1
        ;;
esac

# Add symlink from GOPATH which points into the repository directory:
SYMLINK_LOCATION="$GOPATH_MESOSPHERE/$REPO_NAME"
if [ ! -h "$SYMLINK_LOCATION" -o "$(readlink $SYMLINK_LOCATION)" != "$REPO_ROOT_DIR" ]; then
    echo "Creating symlink from GOPATH=$SYMLINK_LOCATION to REPOPATH=$REPO_ROOT_DIR"
    rm -rf "$SYMLINK_LOCATION"
    mkdir -p "$GOPATH_MESOSPHERE"
    cd $GOPATH_MESOSPHERE
    ln -s "$REPO_ROOT_DIR" $REPO_NAME
fi

# Run 'go get'/'go build' from within GOPATH:
cd $GOPATH_EXE_DIR

go get

# optimization: build a native version of the executable and check if the sha1 matches a
# previous native build. if the sha1 matches, then we can skip the rebuild.
NATIVE_FILENAME="native-${EXE_FILENAME}"
NATIVE_SHA1SUM_FILENAME="${NATIVE_FILENAME}.sha1sum"
go build -o $NATIVE_FILENAME
NATIVE_SHA1SUM=$(sha1sum $NATIVE_FILENAME | awk '{print $1}')

if [ -f $NATIVE_SHA1SUM_FILENAME -a -f $EXE_FILENAME -a "$NATIVE_SHA1SUM" = "$(cat $NATIVE_SHA1SUM_FILENAME)" ]; then
    # build output hasn't changed. skip.
    echo "Skipping rebuild of $EXE_FILENAME: No change to native build"
else
    # build output is missing, or native build changed. build.
    echo "Rebuilding $EXE_FILENAME: Native build SHA1 mismatch or missing output"
    echo $NATIVE_SHA1SUM > $NATIVE_SHA1SUM_FILENAME

    # available GOOS/GOARCH permutations are listed at:
    # https://golang.org/doc/install/source#environment
    CGO_ENABLED=0 GOOS=$2 GOARCH=386 go build -ldflags="-s -w" -o $EXE_FILENAME

    # use upx if available and if golang's output doesn't have problems with it:
    if [ -n "$UPX_BINARY" ]; then
        $UPX_BINARY -q --best $EXE_FILENAME
    fi
fi
