#!/bin/bash

set -eu

declare -r workdir="${PWD}"

declare -r mold_tarball='/tmp/mold.tar.gz'
declare -r mold_directory='/tmp/mold-main'

declare -r zstd_tarball='/tmp/zstd.tar.gz'
declare -r zstd_directory='/tmp/zstd-dev'

declare -r zlib_tarball='/tmp/zlib.tar.gz'
declare -r zlib_directory='/tmp/zlib-develop'

declare -r install_prefix='/tmp/mold-ld'

declare -r max_jobs='30'

declare -r host="${1}"

if ! [ -f "${zstd_tarball}" ]; then
	curl \
		--url 'https://github.com/facebook/zstd/archive/refs/heads/dev.tar.gz' \
		--retry '30' \
		--retry-all-errors \
		--retry-delay '0' \
		--retry-max-time '0' \
		--location \
		--silent \
		--output "${zstd_tarball}"
	
	tar \
		--directory="$(dirname "${zstd_directory}")" \
		--extract \
		--file="${zstd_tarball}"
fi

if ! [ -f "${zlib_tarball}" ]; then
	curl \
		--url 'https://github.com/madler/zlib/archive/refs/heads/develop.tar.gz' \
		--retry '30' \
		--retry-all-errors \
		--retry-delay '0' \
		--retry-max-time '0' \
		--location \
		--silent \
		--output "${zlib_tarball}"
	
	tar \
		--directory="$(dirname "${zlib_directory}")" \
		--extract \
		--file="${zlib_tarball}"
	
	sed \
		--in-place \
		's/(UNIX)/(1)/g; s/(NOT APPLE)/(0)/g' \
		"${zlib_directory}/CMakeLists.txt"
fi

if ! [ -f "${mold_tarball}" ]; then
	curl \
		--url "https://github.com/rui314/mold/archive/main.tar.gz" \
		--retry '30' \
		--retry-all-errors \
		--retry-delay '0' \
		--retry-max-time '0' \
		--location \
		--silent \
		--output "${mold_tarball}"
	
	tar \
		--directory="$(dirname "${mold_directory}")" \
		--extract \
		--file="${mold_tarball}"
fi

[ -d "${zstd_directory}/.build" ] || mkdir "${zstd_directory}/.build"

cd "${zstd_directory}/.build"
rm --force --recursive ./*

cmake \
	-S "${zstd_directory}/build/cmake" \
	-B "${PWD}" \
	-DCMAKE_TOOLCHAIN_FILE="/tmp/${host}.cmake" \
	-DCMAKE_C_FLAGS="-DZDICT_QSORT=ZDICT_QSORT_MIN" \
	-DCMAKE_INSTALL_PREFIX="${CROSS_COMPILE_SYSROOT}" \
	-DZSTD_BUILD_STATIC='ON' \
	-DBUILD_SHARED_LIBS='ON' \
	-DCMAKE_POSITION_INDEPENDENT_CODE='ON' \
	-DCMAKE_PLATFORM_NO_VERSIONED_SONAME='ON' \
	-DZSTD_BUILD_PROGRAMS='OFF' \
	-DZSTD_BUILD_TESTS='OFF'

cmake --build "${PWD}"
cmake --install "${PWD}" --strip

[ -d "${zlib_directory}/.build" ] || mkdir "${zlib_directory}/.build"

cd "${zlib_directory}/.build"
rm --force --recursive ./*

cmake \
	-S "${zlib_directory}" \
	-B "${PWD}" \
	-DCMAKE_TOOLCHAIN_FILE="/tmp/${host}.cmake" \
	-DCMAKE_INSTALL_PREFIX="${CROSS_COMPILE_SYSROOT}" \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON \
	-DZLIB_BUILD_TESTING='OFF'

cmake --build "${PWD}"
cmake --install "${PWD}" --strip

[ -d "${mold_directory}/build" ] || mkdir "${mold_directory}/build"

cd "${mold_directory}/build"
rm --force --recursive ./*

if [[ "${host}" == 'armv5'*'-android'* ]]; then
	export PINO_ARM_MODE=true
fi

declare cmake_flags=''
declare cmake_cxx_flags=''

if [[ "${host}" = *'-darwin'* ]]; then
	cmake_flags+='-DCMAKE_SYSTEM_NAME=Darwin'
fi

if [[ "${host}" != *'-darwin'* ]]; then
	cmake_cxx_flags+='-static-libstdc++ -static-libgcc'
fi

cmake \
	${cmake_flags} \
	-S "${mold_directory}" \
	-B "${mold_directory}/build" \
	-DCMAKE_TOOLCHAIN_FILE="/tmp/${host}.cmake" \
	-DCMAKE_BUILD_TYPE='Release' \
	-DCMAKE_CXX_FLAGS="${cmake_cxx_flags}" \
	-DCMAKE_INSTALL_PREFIX="${install_prefix}" \
	-DLLVM_TOOLCHAIN_TOOLS='mold-ar;mold-ranlib;mold-objdump;mold-rc;mold-cvtres;mold-nm;mold-strings;mold-readobj;mold-dlltool;mold-pdbutil;mold-objcopy;mold-strip;mold-cov;mold-profdata;mold-addr2line;mold-symbolizer;mold-windres;mold-ml;mold-readelf;mold-size;mold-cxxfilt' \
	-Dzstd_LIBRARY="${CROSS_COMPILE_SYSROOT}/lib/libzstd.a" \
	-Dzstd_INCLUDE_DIR="${CROSS_COMPILE_SYSROOT}/include" \
	-DZLIB_LIBRARY="${CROSS_COMPILE_SYSROOT}/lib/libz.a" \
	-DZLIB_INCLUDE_DIR="${CROSS_COMPILE_SYSROOT}/include" \
	-DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
	"${mold_directory}/mold"

cmake --build ./ -- -j '10'
cmake --install ./ --strip

rm --force --recursive ./*

rm \
	--force \
	--recursive \
	"${install_prefix}/lib" \
	"${install_prefix}/include" \
	"${install_prefix}/share"

if [[ "${host}" != *'-darwin'* ]]; then
	[ -d "${install_prefix}/lib" ] || mkdir --parent "${install_prefix}/lib"
	
	# libstdc++
	declare name=$(realpath $("${CC}" --print-file-name='libstdc++.so'))
	
	# libestdc++
	if ! [ -f "${name}" ]; then
		declare name=$(realpath $("${CC}" --print-file-name='libestdc++.so'))
	fi
	
	declare soname=$("${READELF}" -d "${name}" | grep 'SONAME' | sed --regexp-extended 's/.+\[(.+)\]/\1/g')
	
	cp "${name}" "${install_prefix}/lib/${soname}"
	
	# OpenBSD does not have a libgcc library
	if [[ "${CROSS_COMPILE_TRIPLET}" != *'-openbsd'* ]]; then
		# libgcc_s
		declare name=$(realpath $("${CC}" --print-file-name='libgcc_s.so.1'))
		
		# libegcc
		if ! [ -f "${name}" ]; then
			declare name=$(realpath $("${CC}" --print-file-name='libegcc.so'))
		fi
		
		declare soname=$("${READELF}" -d "${name}" | grep 'SONAME' | sed --regexp-extended 's/.+\[(.+)\]/\1/g')
		
		cp "${name}" "${install_prefix}/lib/${soname}"
	fi
fi