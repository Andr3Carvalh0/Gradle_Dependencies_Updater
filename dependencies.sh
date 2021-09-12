#!/bin/bash
#
# Created by André Carvalho on 10th September 2021
# Last modified: 13th September 2021
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
BRANCH_PREFIX="dependencies_bot"

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

	echo ""
	echo "Processing $group:$name..."
	echo "Resetting back to '$mainBranch' branch..."
	git checkout "${mainBranch}"

	if [[ "$(isAlreadyProcessed "$name" "$toVersion")" == "0" ]]; then
		prepareBranch "$name" "$toVersion"
		updateDependenciesFile "$group" "$name" "$fromVersion" "$toVersion" "$gradleDependenciesPath"
		publish "$name" "$toVersion" "$workspace" "$repo" "$user" "$password"
	else
		echo "PR is already open for $group:$name:$toVersion."
	fi
}

function isAlreadyProcessed() {
	local branch="$(id "$1" "$2")"
	git rev-parse --verify "origin/$branch"
	
	local fetchResult="$?"

	if [[ "$fetchResult" != "0" ]]; then
		echo "0"
	else
		echo "1"
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

	echo "Reading '$gradleDependenciesPath' and trying to find if dependency is declared there..."
	local dependency="$(findInFile "$group:$name:" "$gradleDependenciesPath")"

	if [ -n "$dependency" ]; then
		echo "Finding versions.variable name..."
		local versionVariable="$(substring "." "" "$(substring "{" "}" "$dependency")")"

		if [ -n "$versionVariable" ]; then
			echo "Updating $group:$name from $fromVersion to $toVersion"
			local versionVariable="$(substring "." "" "$(substring "{" "}" "$dependency")")"
			
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
			echo "Couldnt find the dependency version variable name."
		fi
	else
		# Happened for example for the gradle tools version. Add support for it in the future after the normal flow is properly tested.
		echo "Couldnt find the dependency declared in the dependency file. Could it be that you are hardcoding it somewhere else?"
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
	local branch="$(id "$name" "$version")"

	echo "Committing changes..."
	git add .
	git commit -m "Update $name to version $version"

	echo "Pushing to origin..."
	git push origin "$branch"

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
					}
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

echo "Fetching '$branch' branch."
git fetch "origin" "$branch"

for row in $(echo "$json" | jq -r '.[] | @base64'); do
	_jq() {
		echo ${row} | base64 --decode | jq -r ${1}
	}

	group=$(_jq '.group')
	name=$(_jq '.name')
	currentVersion=$(_jq '.currentVersion')
	availableVersion=$(_jq '.availableVersion')
	
	main "$group" "$name" "$currentVersion" "$availableVersion" "$gradleDependenciesPath" "$branch" "$workspace" "$repo" "$user" "$password"
	sleep 1
done