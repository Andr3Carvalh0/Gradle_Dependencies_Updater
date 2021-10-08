#!/bin/bash
#
# Created by André Carvalho on 10th September 2021
# Last modified: 8th October 2021
# 
# Processes a json with the format:
#	[
#		{
#			"group": "...",
#			"name": "...",
#			"currentVersion": "...",
#			"availableVersion": "..."
#		},
#		(...)
#	]
#
# And automatically creates a PR for a dependency version update, if needed.
#
BRANCH_PREFIX="dependabot"
SLEEP_DURATION="1"
REMOTE="origin"

function main() {
	local group="$1"
	local name="$2"
	local fromVersion="$3"
	local toVersion="$4"
	local gradleDependenciesPath="$5"
	local mainBranch="$6"
	local workspace="$7"
	local repo="$8"
	local user="$9"
	local password="${10}"
	local reviewers="${11}"
	local versionVariable="$(findVersionsVariableName "$group" "$name" "$gradleDependenciesPath")"

	echo ""

	if [[ "$versionVariable" != "-1" ]]; then
		echo "Processing $group:$name..."
		echo "Resetting back to '$mainBranch' branch..."
		git checkout "${mainBranch}"

		if [[ "$(isAlreadyProcessed "$versionVariable" "$toVersion")" == "0" ]]; then
			prepareBranch "$versionVariable" "$toVersion"
			updateDependenciesFile "$group" "$name" "$fromVersion" "$toVersion" "$gradleDependenciesPath"
			publish "$versionVariable" "$toVersion" "$workspace" "$repo" "$user" "$password" "$gradleDependenciesPath" "$mainBranch" "$reviewers"
		else
			echo "PR is already open for $group:$name:$toVersion."
		fi
	else
		echo "Couldnt find the dependency declared in the dependency file. Could it be that you are hardcoding it somewhere else?"
	fi
}

function isAlreadyProcessed() {
	local branch="$(id "$1" "$2")"
	git ls-remote --exit-code --heads "$REMOTE" "$branch"
	
	local hasError="$?"

	if [[ "$hasError" == "0" ]]; then
		# The git command didn't return an error which means the branch already exists on the remote
		echo "1"
	else
		echo "0"
	fi
}

function prepareBranch() {
	local branch="$(id "$1" "$2")"

	echo "Preparing working branch..."
	git checkout -b "$branch"
}

function updateDependenciesFile() {
	local group="$1"
	local name="$2"
	local fromVersion="$3"
	local toVersion="$4"
	local gradleDependenciesPath="$5"
	local branch="$(id "$name" "$toVersion")"

	local versionVariable="$(findVersionsVariableName "$group" "$name" "$gradleDependenciesPath")"

	if [[ "$versionVariable" != "-1" ]]; then
		echo "Updating $group:$name from $fromVersion to $toVersion"
		# The space at the end of "$versionVariable " is important here. 
		# It prevents false positives when we have something like:
		#
		# ...
		# composeNavigation      : '2.4.0-alpha06',
		# compose                : '1.0.1',
		# ...
		#
		# And we are updating the compose version, and not the composeNavigation, for example
		local originalVersion="$(findInFile "$versionVariable " "$gradleDependenciesPath")"
		local newVersion=$(echo "$originalVersion" | sed "s/${fromVersion}/${toVersion}/g")

		echo "Saving $gradleDependenciesPath file..."
		echo "$(echo "$(cat "$gradleDependenciesPath")" | sed "s/${originalVersion}/${newVersion}/g")" > "$gradleDependenciesPath"
	else
		echo "Couldnt find the dependency declared in the dependency file. Could it be that you are hardcoding it somewhere else?"
	fi
}

function findVersionsVariableName() {
	local group="$1"
	local name="$2"
	local gradleDependenciesPath="$3"
	local dependency="$(findInFile "$group:$name:" "$gradleDependenciesPath")"

	if [ -n "$dependency" ]; then
		local versionVariable="$(substring "." "" "$(substring "{" "}" "$dependency")")"

		if [ -n "$versionVariable" ]; then
			echo "$versionVariable"
		else
			echo "-1"
		fi
	else
		echo "-1"
	fi
}

function findInFile() {
	local text="$1"
	local file="$2"

	while read line; do
		if [[ "$line" == *"$text"* ]]; then
			echo "$line"
			break
		fi
	done < "$file"

	echo ""
}

function substring() {
	local fromChar="$1"
	local untilChar="$2"
	local text="$3"

	if [ -z "$untilChar" ]; then
		echo $(echo $text | awk -F "$fromChar" '{ print $2 }')
	else
		echo "$(sed "s/.*${fromChar}\(.*\)${untilChar}.*/\1/" <<< "$text")"
	fi
}

function publish() {
	local name="$1"
	local version="$2"
	local workspace="$3"
	local repo="$4"
	local user="$5"
	local password="$6"
	local gradleDependenciesPath="$7"
	local mainBranch="$8"
	local reviewers="$9"
	local branch="$(id "$name" "$version")"

	echo "Committing changes..."
	git add "$gradleDependenciesPath"
	git commit -m "Update $name to version $version"

	echo "Pushing to remote..."
	git push "$REMOTE" "$branch"

	if [ -z "$workspace" ] || [ -z "$repo" ] || [ -z "$user" ] || [ -z "$password" ]; then
		echo "Missing params to be able to open a Pull Request. Skipping it..."
	else
		echo "Opening a Pull Request..."
		curl "https://api.bitbucket.org/2.0/repositories/$workspace/$repo/pullrequests" \
			--user "$user:$password" \
			--request "POST" \
			--header "Content-Type: application/json" \
			--data "{ 
					\"title\": \"Update $name to version $version\",
					\"source\": {
						\"branch\": {
							\"name\": \"$branch\"
						}
					},
					$reviewers
					\"destination\": {
						\"branch\": {
							\"name\": \"$mainBranch\"
						}
					},
					\"close_source_branch\": true
				}"
	fi
}

function id() {
	echo "$BRANCH_PREFIX/$1_$2"
}

function help() {
	echo ""
	echo "Usage: $0 -j json -g dependecies file path"
	echo "\t-j, --json\t The dependencies json content."
	echo "\t-g, --gradleDependenciesPath\t The path for the gradle file where the dependencies are declared"
	echo "\t-b, --branch\t The name of the main git branch"
	echo "\t-w, --workspace\t The repos workspace name"
	echo "\t-r, --repo\t The repos name"
	echo "\t-u, --user\t The bitbuckets account username"
	echo "\t-p, --password\t The bitbuckets account password"
	echo "\t--reviewers\t The uuid of the reviewers, separated by ',', to add in the PR"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		-j|-json|--json) json="$2" ;;
		-g|-gradleDependenciesPath|--gradleDependenciesPath) gradleDependenciesPath="$2" ;;
		-b|-branch|--branch) branch="$2" ;;
		-w|-workspace|--workspace) workspace="$2" ;;
		-r|-repo|--repo) repo="$2" ;;
		-u|-user|--user) user="$2" ;;
		-p|-password|--password) password="$2" ;;
		-reviewers|--reviewers) reviewers="$2" ;;
	esac
	shift
	shift
done

if [ -z "$json" ] || [ -z "$gradleDependenciesPath" ]; then
	echo "You are missing one of the require params."
	help
fi

if [ -z "$branch" ]; then
	branch="release"
fi

if [ -n "$reviewers" ]; then
	IFS=',' read -r -a reviewersArray <<< "$reviewers"

	reviewers="\"reviewers\": ["

	for index in "${!reviewersArray[@]}"
	do
		reviewers="$reviewers{ \"uuid\": \"{${reviewersArray[index]}}\" },"
	done

	reviewers="${reviewers::${#reviewers}-1}"
	reviewers="$reviewers],"
else
	reviewers=""
fi

echo "Fetching '$branch' branch."
git fetch "$REMOTE" "$branch"

for row in $(echo "$json" | jq -r '.[] | @base64'); do
	_jq() {
		echo ${row} | base64 --decode | jq -r ${1}
	}

	group=$(_jq '.group')
	name=$(_jq '.name')
	currentVersion=$(_jq '.currentVersion')
	availableVersion=$(_jq '.availableVersion')
	
	main "$group" "$name" "$currentVersion" "$availableVersion" "$gradleDependenciesPath" "$branch" "$workspace" "$repo" "$user" "$password" "$reviewers"

	echo ""
	echo "Sleeping for $SLEEP_DURATION second(s) before continuing..."
	sleep $SLEEP_DURATION
done