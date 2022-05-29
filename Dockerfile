FROM ubuntu:20.04 AS gluten-build
MAINTAINER Hongze Zhang<hongze.zhang@intel.com>

SHELL ["/bin/bash", "-c"]

# REQUIRED PROXYS: APT, WGET, GIT, MAVEN (also Maven mirror)
ARG HTTP_PROXY_HOST
ARG HTTP_PROXY_PORT

ENV http_proxy=${HTTP_PROXY_HOST:+"http://$HTTP_PROXY_HOST:$HTTP_PROXY_PORT"}
ENV https_proxy=${HTTP_PROXY_HOST:+"http://$HTTP_PROXY_HOST:$HTTP_PROXY_PORT"}

RUN if [ -n "$HTTP_PROXY_HOST" ]; then echo "Acquire::http::Proxy \"http://$HTTP_PROXY_HOST:$HTTP_PROXY_PORT\";" >> /etc/apt/apt.conf; fi
RUN if [ -n "$HTTP_PROXY_HOST" ]; then echo "Acquire::https::Proxy \"http://$HTTP_PROXY_HOST:$HTTP_PROXY_PORT\";" >> /etc/apt/apt.conf; fi

ARG MAVEN_MIRROR_URL

RUN if [ -n "$MAVEN_MIRROR_URL" ]; \
    then \
      MAVEN_SETTINGS_TEMPLATE="<settings><mirrors><mirror><id>mavenmirror</id><mirrorOf>central</mirrorOf><name>MavenMirror</name><url>{{MAVEN_MIRROR_URL}}</url></mirror></mirrors><proxies><proxy><id>httpproxy</id><active>{{MAVEN_PROXY_ENABLE}}</active><protocol>http</protocol><host>{{MAVEN_PROXY_HOST}}</host><port>{{MAVEN_PROXY_PORT}}</port></proxy><proxy><id>httpsproxy</id><active>{{MAVEN_PROXY_ENABLE}}</active><protocol>https</protocol><host>{{MAVEN_PROXY_HOST}}</host><port>{{MAVEN_PROXY_PORT}}</port></proxy></proxies></settings>"; \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s@{{MAVEN_MIRROR_URL}}@$MAVEN_MIRROR_URL@g"); \
    else \
      MAVEN_SETTINGS_TEMPLATE="<settings><proxies><proxy><id>httpproxy</id><active>{{MAVEN_PROXY_ENABLE}}</active><protocol>http</protocol><host>{{MAVEN_PROXY_HOST}}</host><port>{{MAVEN_PROXY_PORT}}</port></proxy><proxy><id>httpsproxy</id><active>{{MAVEN_PROXY_ENABLE}}</active><protocol>https</protocol><host>{{MAVEN_PROXY_HOST}}</host><port>{{MAVEN_PROXY_PORT}}</port></proxy></proxies></settings>"; \
    fi \
    && if [ -n "$HTTP_PROXY_HOST" ]; \
    then \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s/{{MAVEN_PROXY_ENABLE}}/true/g"); \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s/{{MAVEN_PROXY_HOST}}/$HTTP_PROXY_HOST/g"); \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s/{{MAVEN_PROXY_PORT}}/$HTTP_PROXY_PORT/g"); \
    else \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s/{{MAVEN_PROXY_ENABLE}}/false/g"); \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s/{{MAVEN_PROXY_HOST}}/localhost/g"); \
      MAVEN_SETTINGS_TEMPLATE=$(echo $MAVEN_SETTINGS_TEMPLATE | sed "s/{{MAVEN_PROXY_PORT}}/8888/g"); \
    fi \
    && MAVEN_SETTINGS=$MAVEN_SETTINGS_TEMPLATE \
    && mkdir -p /root/.m2/ \
    && echo $MAVEN_SETTINGS > /root/.m2/settings.xml

# Display environment information
RUN ulimit -a
RUN env
RUN cat /etc/apt/apt.conf || echo "Apt proxy not set"
RUN cat /root/.m2/settings.xml

# APT dependencies
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tzdata git sudo openjdk-8-jdk llvm-11-dev clang-11 maven libiberty-dev

# USE JAVA 8
RUN apt-get purge -y openjdk-11-jre-headless

ARG TIMEZONE
RUN test -n "$TIMEZONE" || (echo "TIMEZONE not set" && false)

RUN TZ=$TIMEZONE \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && dpkg-reconfigure -f noninteractive tzdata

# These branches are mainly for pre-downloading dependencies to speed-up builds. 
# Thus it should not be required to change these values every time when the build branch
# is changed.
ARG CACHE_VELOX_REPO
ARG CACHE_VELOX_BRANCH
ARG CACHE_ARROW_REPO
ARG CACHE_ARROW_BRANCH
ARG CACHE_GLUTEN_REPO
ARG CACHE_GLUTEN_BRANCH

RUN test -n "$CACHE_VELOX_REPO" || (echo "CACHE_VELOX_REPO not set" && false)
RUN test -n "$CACHE_VELOX_BRANCH" || (echo "CACHE_VELOX_BRANCH not set" && false)
RUN test -n "$CACHE_ARROW_REPO" || (echo "CACHE_ARROW_REPO not set" && false)
RUN test -n "$CACHE_ARROW_BRANCH" || (echo "CACHE_ARROW_BRANCH not set" && false)
RUN test -n "$CACHE_GLUTEN_REPO" || (echo "CACHE_GLUTEN_REPO not set" && false)
RUN test -n "$CACHE_GLUTEN_BRANCH" || (echo "CACHE_GLUTEN_BRANCH not set" && false)

RUN cd /opt/ \
    && git clone $CACHE_VELOX_REPO -b $CACHE_VELOX_BRANCH env-velox
    
RUN cd /opt/ \
    && git clone $CACHE_ARROW_REPO -b $CACHE_ARROW_BRANCH env-arrow

RUN cd /opt/ \
    && git clone $CACHE_GLUTEN_REPO -b $CACHE_GLUTEN_BRANCH env-gluten

RUN cd /opt/env-velox/ \
    && bash scripts/setup-ubuntu.sh
    
# Remove velox's protobuf.
RUN apt-get purge -y protobuf-compiler libprotobuf-dev

# Install protobuf 3.13.0
RUN cd /opt/ \
    && git clone "https://github.com/protocolbuffers/protobuf.git" -b v3.13.0 protobuf-install

RUN cd /opt/protobuf-install \
    && git submodule sync --recursive \
    && git submodule update --init --recursive

RUN cd /opt/protobuf-install \    
    && ./autogen.sh \
    && ./configure CFLAGS=-fPIC CXXFLAGS=-fPIC \
    && make -j$(nproc) \
    && make check \
    && make install \
    && ldconfig

RUN cd /opt/env-arrow/java \
    && mvn clean de.qaware.maven:go-offline-maven-plugin:resolve-dependencies -P arrow-jni,!error-prone,!error-prone-jdk8 -pl dataset,gandiva -am

RUN cd /opt/env-gluten \
    && mvn clean de.qaware.maven:go-offline-maven-plugin:resolve-dependencies -P backends-velox

##

ARG DEBUG_BUILD
RUN test -n "$DEBUG_BUILD" || (echo "DEBUG_BUILD not set" && false)

ARG TARGET_VELOX_REPO
ARG TARGET_VELOX_COMMIT

RUN test -n "$TARGET_VELOX_REPO" || (echo "TARGET_VELOX_REPO not set" && false)
RUN test -n "$TARGET_VELOX_COMMIT" || (echo "TARGET_VELOX_COMMIT not set" && false)

RUN cd /opt/ \
    && git clone $TARGET_VELOX_REPO velox

RUN cd /opt/velox \
    && git fetch origin $TARGET_VELOX_COMMIT:build_$TARGET_VELOX_COMMIT \
    && git checkout build_$TARGET_VELOX_COMMIT

RUN cd /opt/velox \
    && git submodule sync --recursive \
    && git submodule update --init --recursive

RUN cd /opt/velox \
    && make $(if [ "$DEBUG_BUILD" == "ON" ]; then echo "debug"; else echo "release"; fi)

##

ARG TARGET_ARROW_REPO
ARG TARGET_ARROW_COMMIT

RUN test -n "$TARGET_ARROW_REPO" || (echo "TARGET_ARROW_REPO not set" && false)
RUN test -n "$TARGET_ARROW_COMMIT" || (echo "TARGET_ARROW_COMMIT not set" && false)

RUN cd /opt/ \
    && git clone $TARGET_ARROW_REPO arrow

RUN cd /opt/arrow \
    && git fetch origin $TARGET_ARROW_COMMIT:build_$TARGET_ARROW_COMMIT \
    && git checkout build_$TARGET_ARROW_COMMIT
    
RUN cd /opt/arrow/cpp \
    && mkdir build/ \
    && cd build/ \
    && cmake -DCMAKE_BUILD_TYPE=$(if [ "$DEBUG_BUILD" == "ON" ]; then echo "Debug"; else echo "Release"; fi) \
             -DARROW_BUILD_STATIC=OFF \
             -DARROW_BUILD_SHARED=ON \
             -DARROW_SUBSTRAIT=ON \
             -DARROW_COMPUTE=ON \
             -DARROW_GANDIVA_JAVA=ON \
             -DARROW_GANDIVA=ON \
             -DARROW_PARQUET=ON \
             -DARROW_HDFS=ON \
             -DARROW_BOOST_USE_SHARED=OFF \
             -DARROW_JNI=ON \
             -DARROW_DATASET=ON \
             -DARROW_WITH_PROTOBUF=ON \
             -DARROW_WITH_SNAPPY=ON \
             -DARROW_WITH_LZ4=ON \
             -DARROW_WITH_ZSTD=OFF \
             -DARROW_WITH_BROTLI=OFF \
             -DARROW_WITH_ZLIB=OFF \
             -DARROW_WITH_FASTPFOR=ON \
             -DARROW_FILESYSTEM=ON \
             -DARROW_S3=OFF \
             -DARROW_JSON=ON \
             -DARROW_CSV=ON \
             -DARROW_ORC=OFF \
             -DARROW_FLIGHT=OFF \
             -DARROW_JEMALLOC=ON \
             -DARROW_SIMD_LEVEL=AVX2 \
             -DARROW_RUNTIME_SIMD_LEVEL=MAX \
             -DARROW_BUILD_TESTS=OFF \
             -DARROW_PROTOBUF_USE_SHARED=OFF \
             -DARROW_DEPENDENCY_SOURCE=AUTO \
             -DCMAKE_INSTALL_PREFIX=/opt/arrow/cpp/build/bundle \
             ..

RUN NPROC=$(nproc) \
    && cd /opt/arrow/cpp/build/ \
    && make install -j $NPROC

RUN cd /opt/arrow \
    && mkdir -p java/c/build \
    && cd java/c/build \
    && cmake .. \
    && cmake --build .

RUN cd /opt/arrow/java \
    && mvn clean install -P arrow-jni,!error-prone,!error-prone-jdk8 -pl dataset,gandiva -am -Darrow.cpp.build.dir=/opt/arrow/cpp/build/$(if [ "$DEBUG_BUILD" == "ON" ]; then echo "debug"; else echo "release"; fi) -DskipTests -Dcheckstyle.skip=true

##

ARG TARGET_GLUTEN_REPO
ARG TARGET_GLUTEN_COMMIT

RUN test -n "$TARGET_GLUTEN_REPO" || (echo "TARGET_GLUTEN_REPO not set" && false)
RUN test -n "$TARGET_GLUTEN_COMMIT" || (echo "TARGET_GLUTEN_COMMIT not set" && false)

RUN cd /opt/ \
    && git clone $TARGET_GLUTEN_REPO gluten

RUN cd /opt/gluten \
    && git fetch origin $TARGET_GLUTEN_COMMIT:build_$TARGET_GLUTEN_COMMIT \
    && git checkout build_$TARGET_GLUTEN_COMMIT

RUN cd /opt/gluten \
    &&  mvn clean install -Pbackends-velox \
                          -Dbuild_protobuf=OFF \
                          -Dbuild_arrow=OFF \
                          -Dbuild_velox=OFF \
                          -Darrow_root=/opt/arrow/cpp/build/bundle \
                          -Dvelox_home=/opt/velox \
                          -Dvelox_build_type=$(if [ "$DEBUG_BUILD" == "ON" ]; then echo "debug"; else echo "release"; fi) \
                          -Ddebug_build=$DEBUG_BUILD \
                          -Dbuild_cpp=ON \
                          -Dbuild_velox=ON \
                          -Dbuild_gazelle_cpp=ON \
                          -DskipTests \
                          -Dscalastyle.skip=true \
                          -Dcheckstyle.skip=true

# EOF
