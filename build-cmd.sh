#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

PNG_SOURCE_DIR="libpng"

if [ -z "$AUTOBUILD" ] ; then 
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
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

# One of makefiles looks for zlib in zlib\zlib.lib
if [ -d "$stage"/packages/include/zlib ] ; then
    rm -r "$stage"/packages/include/zlib
fi
cp -r "$stage"/packages/include/zlib-ng "$stage"/packages/include/zlib

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/{debug,release}/lib*.so*.disable; do 
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# Unlike grep, expr matches the specified pattern against a string also
# specified on its command line. So our first use of expr to obtain the
# version number went like this:
# expr "$(<libpng/png.h)" ...
# In other words, dump the entirety of png.h into expr's command line and
# search that. Unfortunately, png.h is long enough that on some (Linux!)
# platforms it's too long for the OS to pass. Now we use grep to find the
# right line, and expr to extract just the version number. Because of that, we
# state the relevant symbol name twice. Preface it with ".*" because expr
# implicitly anchors its search to the start of the input string.
symbol="PNG_LIBPNG_VER_STRING"
version="$(expr "$(grep "$symbol" libpng/png.h)" : ".*$symbol \"\([^\"]*\)\"")"
build=${AUTOBUILD_BUILD_ID:=0}
echo "${version}-${build}" > "${stage}/VERSION.txt"

pushd "$PNG_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars
            
            build_sln "projects/vstudio/vstudio.sln" "Release Library|$AUTOBUILD_WIN_VSPLATFORM" "pnglibconf"
            build_sln "projects/vstudio/vstudio.sln" "Release Library|$AUTOBUILD_WIN_VSPLATFORM" "libpng"
            mkdir -p "$stage/lib/release"
            
            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then bitdir=projects/vstudio/Release\ Library
            else bitdir=projects/vstudio/x64/Release\ Library
            fi

            cp -a "$bitdir/libpng16.lib" "$stage/lib/release/libpng16.lib"
            cp -a "$bitdir/libpng16.bsc" "$stage/lib/release/"
            mkdir -p "$stage/include/libpng16"
            cp -a {png.h,pngconf.h,pnglibconf.h} "$stage/include/libpng16"
        ;;

        darwin*)
            opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"
            export CC=clang++

            # Install name for dylibs (if we wanted to build them).
            # The outline of a dylib build is here disabled by '#dylib#' 
            # comments.  The basics:  'configure' won't tolerate an
            # '-install_name' option in LDFLAGS so we have to use the
            # 'install_name_tool' to modify the dylibs after-the-fact.
            # This means that executables and test programs are built
            # with a non-relative path which isn't ideal.
            #
            # Dylib builds should also have "-Wl,-headerpad_max_install_names"
            # options to give the 'install_name_tool' space to work.
            #
            target_name="libpng16.16.dylib"
            install_name="@executable_path/../Resources/${target_name}"

            # Force libz static linkage by moving .dylibs out of the way
            # (Libz is currently packaging only statics but keep this alive...)
            trap restore_dylibs EXIT
            for dylib in "$stage"/packages/lib/{debug,release}/libz*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # See "linux" section for goals/challenges here...
            CFLAGS="$(remove_cxxstd $opts)" \
            CFLAGS="$opts" \
                CXXFLAGS="$opts" \
                CPPFLAGS="${CPPFLAGS:-} -I$stage/packages/include/zlib" \
                LDFLAGS="-L$stage/packages/lib/release" \
                ./configure --prefix="$stage" --libdir="$stage/lib/release" \
                            --with-zlib-prefix="$stage/packages" --enable-shared=no --with-pic
            make
            make install
            #dylib# install_name_tool -id "${install_name}" "${stage}/lib/release/${target_name}"

            # conditionally run unit tests
            #if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #dylib# mkdir -p ./Resources/
                #dylib# ln -sf "${stage}"/lib/release/*.dylib ./Resources/

                #make test
                #dylib# Modify the unit test binaries after-the-fact to point
                #dylib# to the expected path then run the tests again.
                #dylib# 
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngtest
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngstest
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngunknown
                #dylib# install_name_tool -change "${stage}/lib/release/${target_name}" "${install_name}" .libs/pngvalid
                #dylib# make test

                #dylib# rm -rf ./Resources/
            #fi

            # clean the build artifacts
            make distclean
        ;;

        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            # unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per AUTOBUILD_ADDRSIZE
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Force static linkage to libz by moving .sos out of the way
            # (Libz is only packaging statics right now but keep this working.)
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/{debug,release}/libz.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            # 1.16 INSTALL claims ZLIBINC and ZLIBLIB env vars are active but this is not so.
            # If you fail to pick up the correct version of zlib (from packages), the build
            # will find the system's version and generate the wrong PNG_ZLIB_VERNUM definition
            # in the build.  Mostly you won't notice until certain things try to run.  So
            # check the generated pnglibconf.h when doing development and confirm it's correct.
            #
            # The sequence below has the effect of:
            # * Producing only static libraries.
            # * Builds all bin/* targets with static libraries.

            # build the release version and link against the release zlib
            CFLAGS="$(remove_cxxstd $opts)" \
            CFLAGS="$opts" \
                CXXFLAGS="$opts" \
                CPPFLAGS="${CPPFLAGS:-} -I$stage/packages/include/zlib" \
                LDFLAGS="-L$stage/packages/lib/release" \
                ./configure --prefix="$stage" --libdir="$stage/lib/release" \
                            --includedir="$stage/include" --enable-shared=no --with-pic

            make
            make install

            # clean the build artifacts
            make distclean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/libpng.txt"
popd

mkdir -p "$stage"/docs/libpng/
cp -a README.Linden "$stage"/docs/libpng/
