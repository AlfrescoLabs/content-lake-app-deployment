# syntax=docker/dockerfile:1.7
#
# One Dockerfile for every Content Lake service image. Each service is a build target, selected from
# compose with `target:`:
#
#   build:
#     context: .
#     dockerfile: dockerfiles/Dockerfile
#     target: batch-ingester
#     additional_contexts:
#       code: "${CONTENT_LAKE_GIT_CONTEXT:-...}"
#
# Targets: batch-ingester, live-ingester, rag-service, nuxeo-batch-ingester, nuxeo-live-ingester,
#          plugin-batch-ingester, mock-graph
#
# The filesystem source is no longer among them: it ships as a connector jar (content-lake-app#148), which
# is what removed a stage pair and three poms lines from this file rather than adding to them.
#
# App source arrives through the named build context "code" (CONTENT_LAKE_GIT_CONTEXT), which is either
# a git URL or a local path such as ../content-lake-app.
#
# WHY ONE FILE: the reactor's module list has to be enumerated explicitly so that POMs can be copied
# before dependency:go-offline, which is what keeps dependency resolution cached when only sources
# change. That list used to be duplicated verbatim in seven Dockerfiles, so adding or renaming a Maven
# module meant seven identical edits and omitting one broke a service unrelated to the change. It is now
# in exactly one place: the `poms` stage below. Adding a module means adding one line to it.
#
# Do NOT collapse the `poms` stage into a whole-context copy. Copying sources alongside POMs puts every
# source file in the cache key for go-offline, which then re-resolves dependencies on every code change.

# Base images. The defaults are public images; override any of them (for example with a private registry
# mirror or hardened images) by setting the variable of the same name, which compose forwards as a build
# arg when it is set. Global ARGs must be declared before the first FROM to be usable in FROM lines.
#   CONTENT_LAKE_BUILD_IMAGE    Maven + JDK 25, used by the `poms` stage and every build-* stage
#   CONTENT_LAKE_RUNTIME_IMAGE  JRE 25 on Alpine (apk, busybox adduser/addgroup), the service images' base
#   MOCK_GRAPH_IMAGE            JDK 25 on Alpine, the mock-graph target
ARG CONTENT_LAKE_BUILD_IMAGE=maven:3.9.11-eclipse-temurin-25-alpine
ARG CONTENT_LAKE_RUNTIME_IMAGE=eclipse-temurin:25-jre-alpine
ARG MOCK_GRAPH_IMAGE=eclipse-temurin:25-jdk-alpine

############################################################
# poms: the ONLY place the reactor's module list is enumerated
############################################################
FROM ${CONTENT_LAKE_BUILD_IMAGE} AS poms
WORKDIR /workspace

# Group aggregators
COPY --from=code pom.xml .
COPY --from=code common/pom.xml common/pom.xml
COPY --from=code alfresco/pom.xml alfresco/pom.xml
COPY --from=code nuxeo/pom.xml nuxeo/pom.xml
COPY --from=code plugin-runtime/pom.xml plugin-runtime/pom.xml

# Leaf modules. All of them, for every image: Maven needs the full reactor to resolve any subset.
COPY --from=code common/content-lake-repo-model/pom.xml common/content-lake-repo-model/pom.xml
COPY --from=code common/content-lake-spi/pom.xml common/content-lake-spi/pom.xml
COPY --from=code common/content-lake-core/pom.xml common/content-lake-core/pom.xml
COPY --from=code common/rag-service/pom.xml common/rag-service/pom.xml
COPY --from=code alfresco/content-lake-source-alfresco/pom.xml alfresco/content-lake-source-alfresco/pom.xml
COPY --from=code alfresco/alfresco-batch-ingester/pom.xml alfresco/alfresco-batch-ingester/pom.xml
COPY --from=code alfresco/alfresco-live-ingester/pom.xml alfresco/alfresco-live-ingester/pom.xml
COPY --from=code nuxeo/content-lake-source-nuxeo/pom.xml nuxeo/content-lake-source-nuxeo/pom.xml
COPY --from=code nuxeo/nuxeo-batch-ingester/pom.xml nuxeo/nuxeo-batch-ingester/pom.xml
COPY --from=code nuxeo/nuxeo-live-ingester/pom.xml nuxeo/nuxeo-live-ingester/pom.xml
COPY --from=code plugin-runtime/plugin-batch-ingester/pom.xml plugin-runtime/plugin-batch-ingester/pom.xml

# Nothing under plugins/ belongs here. Those projects are outside the reactor on purpose: a connector
# ships as a jar dropped into ./connectors at runtime, not as a module of this build.


############################################################
# runtime-base: everything the service images share
############################################################
FROM ${CONTENT_LAKE_RUNTIME_IMAGE} AS runtime-base
USER root
RUN apk add --no-cache gcompat
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+UseContainerSupport -Dfile.encoding=UTF-8"
ENTRYPOINT ["java","org.springframework.boot.loader.launch.JarLauncher"]


############################################################
# batch-ingester (Alfresco, 9090)
############################################################
FROM poms AS build-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code alfresco/content-lake-source-alfresco/src alfresco/content-lake-source-alfresco/src
COPY --from=code alfresco/alfresco-batch-ingester/src alfresco/alfresco-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 alfresco/alfresco-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS batch-ingester
COPY --from=build-batch-ingester /layers/dependencies/ ./
COPY --from=build-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-batch-ingester /layers/application/ ./
USER app
EXPOSE 9090
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9090/actuator/health || exit 1


############################################################
# live-ingester (Alfresco, 9092)
############################################################
FROM poms AS build-live-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-live-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code alfresco/content-lake-source-alfresco/src alfresco/content-lake-source-alfresco/src
COPY --from=code alfresco/alfresco-live-ingester/src alfresco/alfresco-live-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-live-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 alfresco/alfresco-live-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS live-ingester
COPY --from=build-live-ingester /layers/dependencies/ ./
COPY --from=build-live-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-live-ingester /layers/spring-boot-loader/ ./
COPY --from=build-live-ingester /layers/application/ ./
USER app
EXPOSE 9092
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9092/actuator/health || exit 1


############################################################
# rag-service (9091). No source adapter: it reads from hxpr, it does not ingest.
############################################################
FROM poms AS build-rag-service
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl common/rag-service -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code common/rag-service/src common/rag-service/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl common/rag-service -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 common/rag-service/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS rag-service
COPY --from=build-rag-service /layers/dependencies/ ./
COPY --from=build-rag-service /layers/snapshot-dependencies/ ./
COPY --from=build-rag-service /layers/spring-boot-loader/ ./
COPY --from=build-rag-service /layers/application/ ./
USER app
EXPOSE 9091
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9091/actuator/health || exit 1


############################################################
# nuxeo-batch-ingester (9093)
############################################################
FROM poms AS build-nuxeo-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code nuxeo/content-lake-source-nuxeo/src nuxeo/content-lake-source-nuxeo/src
COPY --from=code nuxeo/nuxeo-batch-ingester/src nuxeo/nuxeo-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 nuxeo/nuxeo-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS nuxeo-batch-ingester
COPY --from=build-nuxeo-batch-ingester /layers/dependencies/ ./
COPY --from=build-nuxeo-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-nuxeo-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-nuxeo-batch-ingester /layers/application/ ./
USER app
EXPOSE 9093
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9093/actuator/health || exit 1


############################################################
# nuxeo-live-ingester (9094). Needs /data for its persisted audit watermark.
############################################################
FROM poms AS build-nuxeo-live-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-live-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code nuxeo/content-lake-source-nuxeo/src nuxeo/content-lake-source-nuxeo/src
COPY --from=code nuxeo/nuxeo-live-ingester/src nuxeo/nuxeo-live-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-live-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 nuxeo/nuxeo-live-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS nuxeo-live-ingester
RUN mkdir -p /data && chown app:app /data
COPY --from=build-nuxeo-live-ingester /layers/dependencies/ ./
COPY --from=build-nuxeo-live-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-nuxeo-live-ingester /layers/spring-boot-loader/ ./
COPY --from=build-nuxeo-live-ingester /layers/application/ ./
USER app
EXPOSE 9094
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9094/actuator/health || exit 1


############################################################
# plugin-batch-ingester (9096)
#
# Builds no source adapter: its connector arrives at runtime as a jar in /opt/content-lake/connectors,
# so only spi, core and the ingester itself are copied.
############################################################
FROM poms AS build-plugin-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl plugin-runtime/plugin-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code plugin-runtime/plugin-batch-ingester/src plugin-runtime/plugin-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl plugin-runtime/plugin-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 plugin-runtime/plugin-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS plugin-batch-ingester
# Somewhere a plugin connector may persist state between runs, such as a change cursor or a delta token.
# Created here and owned by app because Docker copies an image directory's ownership into a fresh named
# volume mounted over it: without this the volume would be root-owned and the non-root process could not
# write to it. Same reason and same shape as /data on nuxeo-live-ingester above.
RUN mkdir -p /var/lib/content-lake/connector && chown app:app /var/lib/content-lake/connector
COPY --from=build-plugin-batch-ingester /layers/dependencies/ ./
COPY --from=build-plugin-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-plugin-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-plugin-batch-ingester /layers/application/ ./
USER app
EXPOSE 9096
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9096/actuator/health || exit 1


############################################################
# mock-graph (8099): a stand-in for Microsoft Graph, for the sharepoint-mock profile
############################################################
# Test tooling rather than a product service, and the only image here that builds no Maven module: the
# mock is a single dependency-free source file, so the JDK's source launcher runs it as it stands. That is
# also why it takes no part in the `poms` stage above, and why adding it did not touch the module list.
#
# A JDK rather than the shared runtime-base, which is a JRE: `java Foo.java` compiles in memory and needs
# a compiler. The same file runs in process from the connector's unit tests, so there is one copy of the
# mock's behaviour rather than a container drifting from what the tests assert.
FROM ${MOCK_GRAPH_IMAGE} AS mock-graph
USER root
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
# The package directories are preserved rather than flattened, because the source launcher refuses a file
# whose path does not match its declared package: `java MockGraphServer.java` on a copy at /app answers
# "end of path to source file does not match its package name". That is why it runs from the source root
# on a developer's machine and needs the same shape here.
COPY --from=code plugins/sharepoint-connector/src/test/java/org/hyland/contentlake/connector/sharepoint/mock/MockGraphServer.java \
     ./org/hyland/contentlake/connector/sharepoint/mock/MockGraphServer.java
COPY --from=code plugins/sharepoint-connector/src/test/resources/fixtures/ /fixtures/
USER app
EXPOSE 8099
ENV MOCK_GRAPH_FIXTURES=/fixtures
# No HEALTHCHECK on purpose: every Graph path requires a bearer token, so an unauthenticated probe would
# answer 401 and mark the container unhealthy. The suite waits on a real request instead.
ENTRYPOINT ["java","org/hyland/contentlake/connector/sharepoint/mock/MockGraphServer.java"]
