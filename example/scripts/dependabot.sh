#!/bin/bash
#
# -Drevision=release overrides the default milestone selection. It fixes, for example, the kotlin version. At the time of writing there was 1.5.31 and 1.6.0-RC
# available. Using the default milestone selection would return kotlin 1.6.0-RC as the latest version, which we dont want. Changing it to release returns the latest stable version
#
set -x
./gradlew dependencyUpdates -Drevision=release

# Verify if the generated json has any dependency to update.
# If not, exit now.
jsonContent="$(cat "./build/dependencies/report.json")"

if [[ -z "$jsonContent" ]]; then
	exit 0
fi

# Start processing the generated json from ben manes plugin.
./scripts/dependencies/dependencies.sh --json "$jsonContent" \
	--gradleDependenciesPath "./gradle/dependencies.gradle"

	# Other params are:
	# You can read all about it in the help from the dependencies script.
	# 
	# --branch "$BITRISE_GIT_BRANCH" \
	# --workspace "$BITBUCKET_WORKSPACE" --repo "$BITBUCKET_REPO" \
	# --user "$BOT_BITBUCKET_USER" --password "$BOT_BITBUCKET_TOKEN" \
	# --reviewers "UUID1,UUID2..." \
	# --script "./scripts/dependencies/changelog.sh"