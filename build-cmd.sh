#!/usr/bin/env bash

cd "$(dirname "$0")"

set -e

PNG_SOURCE_DIR="libpng"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

stage="$(pwd)/stage"

# load autobuild-provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

[ -f "$stage"/packages/include/zlib-ng/zlib.h ] || \
{ echo "Run 'autobuild install' first." 1>&2 ; exit 1; }

pushd "$PNG_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

            mkdir -p "build"
            pushd "build"
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS:STRING="$plainopts" \
                    -DCMAKE_CXX_FLAGS:STRING="$opts" \
                    -DPNG_SHARED=ON \
                    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                    -DZLIB_INCLUDE_DIR="$(cygpath -m "$stage/packages/include/zlib-ng/")" \
                    -DZLIB_LIBRARY="$(cygpath -m "$stage/packages/lib/release/zlib.lib")" \
                    -DCMAKE_INSTALL_PREFIX=$(cygpath -m $stage)

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi

                cmake --install . --config Release

                mkdir -p $stage/lib/release/
                mv $stage/lib/libpng16_static.lib "$stage/lib/release/libpng16.lib"
            popd
        ;;

        darwin*)
            export MACOSX_DEPLOYMENT_TARGET="$LL_BUILD_DARWIN_DEPLOY_TARGET"

            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $opts)"
                ld_opts="$ARCH_ARGS"

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    CXXFLAGS="$opts" \
                    LDFLAGS="$ld_opts" \
                    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_C_FLAGS:STRING="$cc_opts" \
                        -DCMAKE_CXX_FLAGS:STRING="$opts" \
                        -DPNG_SHARED=ON \
                        -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                        -DZLIB_INCLUDE_DIR="$stage/packages/include/zlib-ng/" \
                        -DZLIB_LIBRARY="$stage/packages/lib/release/libz.a" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                        -DCMAKE_OSX_ARCHITECTURES="$arch"

                    cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

                    # conditionally run unit tests
                    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                        ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                    fi

                    cmake --install . --config Release
                popd
            done

            # Create universal library
            lipo -create -output "$stage/lib/release/libpng16.a" "$stage/lib/release/x86_64/libpng16.a" "$stage/lib/release/arm64/libpng16.a"
            cp -a "$stage"/lib/release/x86_64/libpng.a "$stage"/lib/release/
        ;;

        linux*)
            mkdir -p "build"
            pushd "build"

            # Default target per AUTOBUILD_ADDRSIZE
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"

            cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_FLAGS:STRING="$(remove_cxxstd $opts)" \
                -DCMAKE_CXX_FLAGS:STRING="$opts" \
                -DPNG_SHARED=ON \
                -DPNG_HARDWARE_OPTIMIZATIONS=ON \
                -DZLIB_INCLUDE_DIR="$stage/packages/include/zlib-ng/" \
                -DZLIB_LIBRARY="$stage/packages/lib/release/libz.a" \
                -DCMAKE_INSTALL_PREFIX="$stage" \
                -DCMAKE_INSTALL_LIBDIR="$stage/lib/release"

            cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
            fi

            cmake --install . --config Release
            popd
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/libpng.txt"
popd

mkdir -p "$stage"/docs/libpng/
