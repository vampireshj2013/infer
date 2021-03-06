#!/bin/bash

# Copyright (c) 2013 - present Facebook, Inc.
# All rights reserved.
#
# This source code is licensed under the BSD style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

set -x
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_INFER_DIR="$SCRIPT_DIR"/..
CLANG_PLUGIN_DIR="$ROOT_INFER_DIR"/facebook-clang-plugins
PLATFORM=`uname`
INFER_SOURCE="$ROOT_INFER_DIR"/infer-source

# Build infer and facebook-clang-plugins
cd "$ROOT_INFER_DIR"
# This assumes the current commit is the one with the release bump
git submodule update --init --recursive
facebook-clang-plugins/clang/setup.sh
./compile-fcp.sh
make -C infer


# Get a copy of the github repo
git clone https://github.com/facebook/infer.git "$INFER_SOURCE"
pushd "$INFER_SOURCE"
# Name of the release package
VERSION=`git describe --abbrev=0 --tags`
if [ "$PLATFORM" == 'Darwin' ]; then
    RELEASE_NAME=infer-osx-"$VERSION"
else
    RELEASE_NAME=infer-linux64-"$VERSION"
fi
RELEASE_TARBALL="$RELEASE_NAME".tar.xz
PKG_DIR="$ROOT_INFER_DIR"/"$RELEASE_NAME"

git checkout "$VERSION"
popd

# Copy infer source
mkdir -p "$PKG_DIR"
rsync -a --exclude=".git/" --exclude=".gitmodules" --exclude=".gitignore" "$INFER_SOURCE"/ "$PKG_DIR"
touch "$PKG_DIR"/.release

# Add facebook-clang-plugin binaries
PKG_PLUGIN_DIR="$PKG_DIR"/facebook-clang-plugins
mkdir -p "$PKG_PLUGIN_DIR"/clang/{bin,lib,include}
mkdir -p "$PKG_PLUGIN_DIR"/libtooling/build
mkdir -p "$PKG_PLUGIN_DIR"/clang-ocaml/build
cp "$CLANG_PLUGIN_DIR"/{CONTRIBUTING.md,LICENSE,LLVM-LICENSE,PATENTS,README.md} "$PKG_PLUGIN_DIR"
cp -r "$CLANG_PLUGIN_DIR"/clang/bin/clang* "$PKG_PLUGIN_DIR"/clang/bin
cp -r $CLANG_PLUGIN_DIR/clang/lib/* "$PKG_PLUGIN_DIR"/clang/lib
cp -r "$CLANG_PLUGIN_DIR"/clang/include/* "$PKG_PLUGIN_DIR"/clang/include
rm -f "$PKG_PLUGIN_DIR"/clang/lib/*.a

cp -r "$CLANG_PLUGIN_DIR"/libtooling/build/* "$PKG_PLUGIN_DIR"/libtooling/build
cp -r "$CLANG_PLUGIN_DIR"/clang-ocaml/build/* "$PKG_PLUGIN_DIR"/clang-ocaml/build
cp -r "$CLANG_PLUGIN_DIR"/clang-ocaml/*.ml "$PKG_PLUGIN_DIR"/clang-ocaml/

FBONLY=FB-ONLY
if grep -Ir --exclude="package_infer_source_with_clang_binaries.sh" "$FBONLY" "$PKG_DIR"; then
    echo "Found files marked $FBONLY"
    exit 1
fi

cd "$ROOT_INFER_DIR" && tar cJf "$RELEASE_TARBALL" "$RELEASE_NAME"

# Cleanup.
rm -rf "$PKG_DIR" "$INFER_SOURCE"

# vim: sw=2 ts=2 et:
