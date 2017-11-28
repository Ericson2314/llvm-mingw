FROM ubuntu:16.04

#FIXME: Remove vim once debuging is complete
# git-svn is only used to get sensible version numbers in clang version printouts
RUN apt-get update -qq && apt-get install -qqy \
    git wget bzip2 file libwine-development-dev unzip libtool pkg-config cmake \
    build-essential automake texinfo ragel yasm p7zip-full gettext autopoint \
    vim python git-svn


RUN git config --global user.name "LLVM MinGW" && \
    git config --global user.email root@localhost

WORKDIR /build

# When cloning master and checking out a pinned old hash, we can't use --depth=1.
RUN git clone -b master https://github.com/llvm-mirror/llvm.git && \
    cd llvm/tools && \
    git clone -b master https://github.com/llvm-mirror/clang.git && \
    git clone -b master https://github.com/llvm-mirror/lld.git && \
    cd .. && \
    git svn init https://llvm.org/svn/llvm-project/llvm/trunk && \
    git config svn-remote.svn.fetch :refs/remotes/origin/master && \
    git svn rebase -l && \
    git checkout 305f0fb15600a5e4a247a8bcf230d4fbf56ac6ba && \
    cd tools/clang && \
    git svn init https://llvm.org/svn/llvm-project/cfe/trunk && \
    git config svn-remote.svn.fetch :refs/remotes/origin/master && \
    git svn rebase -l && \
    git checkout fb2fbcc95291e95c593f9e5d5712a3fdd82c186a && \
    cd ../lld && \
    git checkout bdb0db17cbabf8ad325ed3cd21054aec17056680


# Build LLVM
RUN cd llvm && mkdir build && cd build && cmake \
    -DCMAKE_INSTALL_PREFIX="/build/prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_TARGETS_TO_BUILD="ARM;AArch64;X86" \
    ../ && \
    make -j4 && \
    make install

RUN git clone git://git.code.sf.net/p/mingw-w64/mingw-w64 && \
    cd mingw-w64 && \
    git checkout d958789c106b4470f75c88bfe9484e5ba0510503


ENV TOOLCHAIN_PREFIX=/build/prefix
ENV PATH=$TOOLCHAIN_PREFIX/bin:$PATH

RUN cd mingw-w64/mingw-w64-headers && \
    for arch in armv7 aarch64 i686 x86_64; do \
        mkdir build-${arch} && cd build-${arch} && \
        ../configure --host=${arch}-w64-mingw32 --prefix=$TOOLCHAIN_PREFIX/${arch}-w64-mingw32 \
            --enable-secure-api --with-default-win32-winnt=0x600 && \
        make install && \
        cd .. || exit 1; \
    done

# Install the usual $TUPLE-clang binaries
RUN mkdir /build/wrappers
COPY wrappers/clang-target-wrapper /build/wrappers
RUN for arch in armv7 aarch64 i686 x86_64; do \
        for exec in clang clang++; do \
            cp wrappers/clang-target-wrapper $TOOLCHAIN_PREFIX/bin/${arch}-w64-mingw32-${exec}; \
        done; \
    done

# Build mingw with our freshly built cross compiler
RUN cd mingw-w64/mingw-w64-crt && \
    for arch in armv7 aarch64 i686 x86_64; do \
        mkdir build-$arch && cd build-$arch && \
        case $arch in \
        armv7) \
            FLAGS="--disable-lib32 --disable-lib64 --enable-libarm32" \
            ;; \
        aarch64) \
            FLAGS="--disable-lib32 --disable-lib64 --enable-libarm64" \
            ;; \
        i686) \
            FLAGS="--enable-lib32 --disable-lib64" \
            ;; \
        x86_64) \
            FLAGS="--disable-lib32 --enable-lib64" \
            ;; \
        esac && \
        CC=$arch-w64-mingw32-clang \
        AR=llvm-ar RANLIB=llvm-ranlib DLLTOOL=llvm-dlltool ../configure --host=$arch-w64-mingw32 --prefix=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 $FLAGS && \
        make -j4 && make install && \
        cd .. || exit 1; \
    done

#RUN cp /build/mingw-w64/mingw-w64-libraries/winpthreads/include/* $MINGW_PREFIX/include/

RUN git clone -b master https://github.com/llvm-mirror/compiler-rt.git && \
    cd compiler-rt && \
    git checkout de9856b41224c2e7c30d0991d032f5efcf6d43e7

# Add a symlink for i386 -> i686; we normally name the toolchain
# i686-w64-mingw32, but due to the compiler-rt cmake peculiarities, we
# need to refer to it as i386 at this stage.
RUN cd /build/prefix && ln -s i686-w64-mingw32 i386-w64-mingw32

# Manually build compiler-rt as a standalone project
RUN cd compiler-rt && \
    for arch in armv7 aarch64 i686 x86_64; do \
        buildarchname=$arch && \
        libarchname=$arch && \
        case $arch in \
        armv7) \
            libarchname=arm \
            ;; \
        i686) \
            buildarchname=i386 \
            libarchname=i386 \
            ;; \
        esac && \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/llvm-ar \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/llvm-ranlib \
            -DCMAKE_C_COMPILER_WORKS=1 \
            -DCMAKE_C_COMPILER_TARGET=$buildarchname-windows-gnu \
            -DCOMPILER_RT_DEFAULT_TARGET_ONLY=TRUE \
            ../lib/builtins && \
        make -j4 && \
        mkdir -p /build/prefix/lib/clang/6.0.0/lib/windows && \
        cp lib/windows/libclang_rt.builtins-$buildarchname.a /build/prefix/lib/clang/6.0.0/lib/windows/libclang_rt.builtins-$libarchname.a && \
        cd .. || exit 1; \
    done

#RUN cd mingw-w64/mingw-w64-libraries && cd winstorecompat && \
#    autoreconf -vif && \
#    mkdir build && cd build && \
#    ../configure --host=$TARGET_TUPLE --prefix=$MINGW_PREFIX && make && make install

#RUN cd /build/mingw-w64/mingw-w64-tools/widl && \
#    mkdir build && cd build && \
#    CC=gcc \
#    ../configure --prefix=$TOOLCHAIN_PREFIX --target=$TARGET_TUPLE && \
#    make -j4 && \
#    make install

RUN git clone -b master https://github.com/llvm-mirror/libcxx.git && \
    git clone -b master https://github.com/llvm-mirror/libcxxabi.git && \
    git clone -b master https://github.com/llvm-mirror/libunwind.git && \
    cd libcxx && \
    git checkout f45f32b0254e4107b4165ddc99ca2503ab9bd754 && \
    cd ../libcxxabi && \
    git checkout 05ba3281482304ae8de31123a594972a495da06d && \
    cd ../libunwind && \
    git checkout 2ddcf2461daa5d61c543474aed06b12a8b9ad816


RUN cd libcxxabi && \
    for arch in armv7 aarch64 i686 x86_64; do \
        EXCEPTIONS=ON && \
        case $arch in \
        aarch64) \
            EXCEPTIONS=OFF \
            ;; \
        esac && \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
            -DCMAKE_CROSSCOMPILING=TRUE \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_C_COMPILER_WORKS=TRUE \
            -DCMAKE_CXX_COMPILER_WORKS=TRUE \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/llvm-ar \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/llvm-ranlib \
            -DLIBCXXABI_USE_COMPILER_RT=ON \
            -DLIBCXXABI_ENABLE_EXCEPTIONS=$EXCEPTIONS \
            -DLIBCXXABI_ENABLE_THREADS=ON \
            -DLIBCXXABI_TARGET_TRIPLE=$arch-w64-mingw32 \
            -DLIBCXXABI_ENABLE_SHARED=OFF \
            -DLIBCXXABI_LIBCXX_INCLUDES=../../libcxx/include \
            -DLLVM_NO_OLD_LIBSTDCXX=TRUE \
            -DCXX_SUPPORTS_CXX11=TRUE \
            -DCMAKE_CXX_FLAGS="-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS" \
            .. && \
        make -j4 && \
        cd .. || exit 1; \
    done

RUN cd libcxx && \
    for arch in armv7 aarch64 i686 x86_64; do \
        EXCEPTIONS=ON && \
        case $arch in \
        aarch64) \
            EXCEPTIONS=OFF \
            ;; \
        esac && \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
            -DCMAKE_CROSSCOMPILING=TRUE \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_C_COMPILER_WORKS=TRUE \
            -DCMAKE_CXX_COMPILER_WORKS=TRUE \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/llvm-ar \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/llvm-ranlib \
            -DLIBCXX_USE_COMPILER_RT=ON \
            -DLIBCXX_INSTALL_HEADERS=ON \
            -DLIBCXX_ENABLE_EXCEPTIONS=$EXCEPTIONS \
            -DLIBCXX_ENABLE_THREADS=ON \
            -DLIBCXX_ENABLE_MONOTONIC_CLOCK=ON \
            -DLIBCXX_ENABLE_SHARED=OFF \
            -DLIBCXX_SUPPORTS_STD_EQ_CXX11_FLAG=TRUE \
            -DLIBCXX_HAVE_CXX_ATOMICS_WITHOUT_LIB=TRUE \
            -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
            -DLIBCXX_ENABLE_FILESYSTEM=OFF \
            -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE \
            -DLIBCXX_CXX_ABI=libcxxabi \
            -DLIBCXX_CXX_ABI_INCLUDE_PATHS=../../libcxxabi/include \
            -DLIBCXX_CXX_ABI_LIBRARY_PATH=../../libcxxabi/build-$arch/lib \
            -DCMAKE_CXX_FLAGS="-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS" \
            .. && \
        make -j4 && make install && \
        cd .. || exit 1; \
    done

RUN cd /build/prefix/include && ln -s /build/prefix/armv7-w64-mingw32/include/c++ .

RUN cd libunwind && \
    for arch in armv7 i686 x86_64; do \
        mkdir build-$arch && cd build-$arch && cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=$TOOLCHAIN_PREFIX/$arch-w64-mingw32 \
            -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
            -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
            -DCMAKE_CROSSCOMPILING=TRUE \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_C_COMPILER_WORKS=TRUE \
            -DCMAKE_CXX_COMPILER_WORKS=TRUE \
            -DCMAKE_AR=$TOOLCHAIN_PREFIX/bin/llvm-ar \
            -DCMAKE_RANLIB=$TOOLCHAIN_PREFIX/bin/llvm-ranlib \
            -DLLVM_NO_OLD_LIBSTDCXX=TRUE \
            -DLIBUNWIND_USE_COMPILER_RT=TRUE \
            -DLIBUNWIND_ENABLE_THREADS=TRUE \
            -DLIBUNWIND_ENABLE_SHARED=FALSE \
            -DLIBUNWIND_ENABLE_CROSS_UNWINDING=FALSE \
            .. && \
        make -j4 && make install && \
        ../../libcxx/utils/merge_archives.py \
            --ar llvm-ar \
            -o $TOOLCHAIN_PREFIX/$arch-w64-mingw32/lib/libc++.a \
            $TOOLCHAIN_PREFIX/$arch-w64-mingw32/lib/libc++.a \
            lib/libunwind.a && \
        cd .. || exit 1; \
    done

RUN mkdir -p /build/hello
COPY hello.c hello.cpp hello-exception.cpp /build/hello/
RUN cd /build/hello && \
    for arch in armv7 aarch64 x86_64 i686; do \
        $arch-w64-mingw32-clang hello.c -o hello-$arch.exe || exit 1; \
    done

RUN cd /build/hello && \
    for arch in armv7 aarch64 x86_64 i686; do \
        $arch-w64-mingw32-clang++ hello.cpp -o hello-cpp-$arch.exe -fno-exceptions || exit 1; \
    done

RUN cd /build/hello && \
    for arch in armv7 x86_64 i686; do \
        $arch-w64-mingw32-clang++ hello-exception.cpp -o hello-exception-$arch.exe || exit 1; \
    done

ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV AS=llvm-as
ENV NM=llvm-nm
