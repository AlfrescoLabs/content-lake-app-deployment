FROM maven:3-eclipse-temurin-25-alpine AS build

ARG HXPR_GIT_URL=https://github.com/Hyland/OpenArch.git
ARG HXPR_GIT_REF=main
# Optional: pin to a specific commit SHA for reproducible builds.
# When set, the clone is done without --depth 1 so the SHA can be checked out.
ARG HXPR_GIT_SHA=

RUN apk add --no-cache git bash

WORKDIR /workspace

RUN <<'SCRIPT'
set -e
if [ -n "$HXPR_GIT_SHA" ]; then
    git clone --branch "$HXPR_GIT_REF" "$HXPR_GIT_URL" hxpr
    git -C hxpr checkout "$HXPR_GIT_SHA"
else
    git clone --depth 1 --branch "$HXPR_GIT_REF" "$HXPR_GIT_URL" hxpr
fi
SCRIPT

WORKDIR /workspace/hxpr

RUN --mount=type=cache,target=/root/.m2/repository \
    mvn --no-transfer-progress -nsu -pl server/openarch-app -am package -DskipTests

# Public Amazon Corretto 25 on Alpine. The runtime stage needs only a JRE 25, curl and busybox
# adduser/addgroup, so a public base keeps the image build free of credential-gated registries.
FROM amazoncorretto:25-alpine

ARG RUN_JAVA_VERSION=1.3.8
ARG GROUP_NAME=Hyland
ARG GROUP_ID=1000
ARG USER_NAME=hxpr-app-user
ARG USER_ID=33010

ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en'
ENV JAVA_OPTIONS=""

RUN apk add --no-cache curl \
    && mkdir /deployments \
    && curl https://repo1.maven.org/maven2/io/fabric8/run-java-sh/${RUN_JAVA_VERSION}/run-java-sh-${RUN_JAVA_VERSION}-sh.sh -o /deployments/run-java.sh

COPY --from=build /workspace/hxpr/server/openarch-app/target/openarch-app-*.jar /deployments/

RUN addgroup -g ${GROUP_ID} ${GROUP_NAME} && \
    adduser -D -u ${USER_ID} -G ${GROUP_NAME} ${USER_NAME} && \
    chown -R ${USER_NAME}:${GROUP_NAME} /deployments && \
    chmod +x /deployments/run-java.sh

RUN sed -i 's/#networkaddress.cache.ttl=-1/networkaddress.cache.ttl=0/' $JAVA_HOME/conf/security/java.security

EXPOSE 8080

USER ${USER_NAME}

ENTRYPOINT ["/deployments/run-java.sh"]
