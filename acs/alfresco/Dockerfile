# syntax=docker/dockerfile:1.7
#
# The eighth build that depends on content-lake-app's module layout, and the one that is easy to miss:
# the other seven are the service images in dockerfiles/Dockerfile. This one is not a Content Lake
# service at all, it is the Alfresco repository with the Content Lake content model installed into it.
#
# It names common/content-lake-repo-model twice, below. If that module moves, both lines change.
# Unlike the service images it copies the whole source context rather than enumerating POMs, so adding
# or renaming any OTHER module does not affect it.
#
# Its source context is named content_lake_app (CONTENT_LAKE_ACS_GIT_CONTEXT), not code.
#
# It stays on temurin-21 while the rest of the build uses 25 because content-lake-repo-model is pinned
# to Java 17 for Alfresco SDK compatibility, and the root POM it inherits compiles nothing itself.

# Global ARGs must be declared before any FROM so they can be used in FROM instructions.
ARG ALFRESCO_TAG
# Override (for example with a private registry mirror) by setting ACS_MODEL_BUILD_IMAGE; compose forwards it when set.
ARG ACS_MODEL_BUILD_IMAGE=maven:3.9.9-eclipse-temurin-21-alpine

############################################
# Stage 1: Build content-lake-repo-model from source
############################################
FROM ${ACS_MODEL_BUILD_IMAGE} AS model-build

WORKDIR /src

COPY --from=content_lake_app . .

RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl common/content-lake-repo-model -am package

############################################
# Stage 2: Alfresco with the model JAR
############################################
FROM alfresco/alfresco-content-repository-community:${ALFRESCO_TAG}

ARG TOMCAT_DIR=/usr/local/tomcat

USER root

COPY --from=model-build /src/common/content-lake-repo-model/target/content-lake-repo-model-*.jar \
  ${TOMCAT_DIR}/webapps/alfresco/WEB-INF/lib/

USER alfresco
