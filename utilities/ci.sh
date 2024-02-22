#!/usr/bin/env bash
#
# Created by André Carvalho on 1st February 2024
# Last modified: 19th February 2024
#
# Uses Ben-Manes' gradle dependecies updater, to check which libraries have updates available.
# For each update available create a PR where we bump the library version automatically
#
readonly RED='\033[0;31m'
readonly RESET='\033[0m'

readonly PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly CLONED_DIRECTORY="${PROJECT_DIRECTORY}/donald-duck-android"

if [[ -z "$CI" || "$CI" == "false" ]]; then
	echo -e "\n${RED}❌ This script must be run in the CI/CD pipeline... ${RESET}"
	exit 1
fi

rm -rf "${PROJECT_DIRECTORY}/build/dependencies"

# With Gradle 8.4+ the ability of random plugins parsing Gradle functions output is been cut from security reasons
# We enabled them back with the javax.xml.parsers params here, since we trust this command.
"${PROJECT_DIRECTORY}/gradlew" --no-configuration-cache dependencyUpdates \
	-Djavax.xml.parsers.SAXParserFactory=com.sun.org.apache.xerces.internal.jaxp.SAXParserFactoryImpl \
	-Djavax.xml.transform.TransformerFactory=com.sun.org.apache.xalan.internal.xsltc.trax.TransformerFactoryImpl \
	-Djavax.xml.parsers.DocumentBuilderFactory=com.sun.org.apache.xerces.internal.jaxp.DocumentBuilderFactoryImpl

# Verify if the generated json has any dependency to update. If not, exit now.
readonly json="$(cat "${PROJECT_DIRECTORY}/build/dependencies/report.json")"

if [[ -z "$json" ]]; then
	exit 0
fi

function cleanup() {
	local exitCode="$?"

	if [[ -d "$CLONED_DIRECTORY" ]]; then
		rm -rf "$CLONED_DIRECTORY"
	fi

	exit $exitCode
}

trap cleanup SIGHUP SIGINT SIGQUIT SIGABRT EXIT

# We dont work over the CI/CD cloned pipeline, we clone it ourselves
git clone https://x-token-auth:"$BITBUCKET_TOKEN"@bitbucket.org/$WORKSPACE/$REPO.git
git -C "$CLONED_DIRECTORY" config user.email "$BITBUCKET_EMAIL"
git -C "$CLONED_DIRECTORY" config user.name "André Carvalho"

cd "$CLONED_DIRECTORY" && "${SCRIPT_DIRECTORY}/dependencies.sh" --json "$json" \
	--dependencies "${CLONED_DIRECTORY}/buildSrc/src/main/kotlin/Libraries.kt,${CLONED_DIRECTORY}/build.gradle.kts" \
	--versions "${CLONED_DIRECTORY}/buildSrc/src/main/kotlin/Versions.kt" \
	--branch "develop" \
	--callback "${SCRIPT_DIRECTORY}/make_pull_request.sh"
