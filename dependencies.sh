#!/bin/bash
#
# Created by André Carvalho on 10th September 2021
# Last modified: 29th October 2021
#
# Processes a json with the format:
#	[
#		{
#			"group": "...",
#			"name": "...",
#			"currentVersion": "...",
#			"availableVersion": "...",
#			"changelog": "..."
#		},
#		(...)
#	]
#
# And automatically creates a PR for a dependency version update, if needed.
#
BRANCH_PREFIX="dependabot"
SLEEP_DURATION="1"
REMOTE="origin"
DEFAULT_BRANCH="release"

function main() {
	local extVersionVariable="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local changelog="$4"
	local gradleDependenciesPath="$5"
	local mainBranch="$6"
	local workspace="$7"
	local repo="$8"
	local user="$9"
	local password="${10}"
	local reviewers="${11}"
	local script="${12}"

	log "\nResetting back to '$mainBranch' branch..."
	git checkout "${mainBranch}"

	prepareBranch "$extVersionVariable" "$toVersion"
	updateDependenciesFile "$extVersionVariable" "$fromVersion" "$toVersion" "$gradleDependenciesPath"
	publish "$extVersionVariable" "$fromVersion" "$toVersion" "$workspace" "$repo" "$user" "$password" "$gradleDependenciesPath" "$mainBranch" "$reviewers" "$changelog" "$script"
}

function isAlreadyProcessed() {
	local branch="$(id "$1" "$2")"
	local command="$(git ls-remote --exit-code --heads "$REMOTE" "$branch")"

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

	log "\nPreparing working branch..."
	git checkout -b "$branch"
}

function updateDependenciesFile() {
	local extVersionVariable="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local gradleDependenciesPath="$4"

	log "\nUpdating '$extVersionVariable' from '$fromVersion' to '$toVersion'"
	# The space at the end of "$extVersionVariable " is important here.
	# It prevents false positives when we have something like:
	#
	# ...
	# composeNavigation      : '2.4.0-alpha06',
	# compose                : '1.0.1',
	# ...
	#
	# And we are updating the compose version, and not the composeNavigation, for example
	local originalVersion="$(findInFile "$extVersionVariable " "$gradleDependenciesPath")"

	if [ -z "$originalVersion" ]; then
		log "Couldnt find the original version declaration. Please check if you declared with a space after the ':'. eg: KEY : VALUE"
	else
		local newVersion=$(echo "$originalVersion" | sed "s/${fromVersion}/${toVersion}/g")

		log "Saving $gradleDependenciesPath file..."
		echo "$(echo "$(cat "$gradleDependenciesPath")" | sed "s/${originalVersion}/${newVersion}/g")" > "$gradleDependenciesPath"
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

function log() {
	printf "$1\n"
}

function publish() {
	local name="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local workspace="$4"
	local repo="$5"
	local user="$6"
	local password="$7"
	local gradleDependenciesPath="$8"
	local mainBranch="$9"
	local reviewers="${10}"
	local changelog="${11}"
	local script="${12}"
	local branch="$(id "$name" "$toVersion")"

	log "\nCommitting changes..."
	git add "$gradleDependenciesPath"

	if [[ `git status --porcelain` ]]; then
		if [ -n "$script" ]; then
			log "\nExecuting post script: '${script}'..."
			$script "$name" "$fromVersion" "$toVersion"
		fi

		git commit -m "Update $name to version $toVersion"

		log "\nPushing changes to remote..."
		git push --force "$REMOTE" "$branch"

		if [ -z "$workspace" ] || [ -z "$repo" ] || [ -z "$user" ] || [ -z "$password" ]; then
			log "\nMissing params to be able to open a Pull Request. Skipping it..."
		else
			log "\nOpening a Pull Request..."
			curl "https://api.bitbucket.org/2.0/repositories/$workspace/$repo/pullrequests" \
				--user "$user:$password" \
				--request "POST" \
				--header "Content-Type: application/json" \
				--data "{
						\"title\": \"Update $name to version $toVersion\",
						\"description\": \"It updates:\n\n$changelog\",
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
	else
		log "\nNothing to push. Skipping..."
	fi
}

function id() {
	echo "$BRANCH_PREFIX/$1_$2"
}

function differencesBetween() {
	local fromBranch="$1"
	local toBranch="$2"

	# Returns the amount of changes that both branches had since their split
	# Eg: Imagining that fromBranch is release and toBranch develop after both being created the output would be 0 0
	# If I create a commit in develop it becomes 0 1, and if I later commit in release it becomes 1 1
	local command="$(git rev-list --left-right --count "$REMOTE/$fromBranch"..."$REMOTE/$toBranch")"
	local diff=( $command )

	echo "${versions[0]}"
}

function help() {
	log "Usage: $0 -j json -g dependecies file path"
	log "\t-j, --json\t The dependencies json content."
	log "\t-g, --gradleDependenciesPath\t The path for the gradle file where the dependencies are declared"
	log "\t-b, --branch\t The name of the main git branch"
	log "\t-w, --workspace\t The repos workspace name"
	log "\t-r, --repo\t The repos name"
	log "\t-u, --user\t The bitbuckets account username"
	log "\t-p, --password\t The bitbuckets account password"
	log "\t--reviewers\t The uuid of the reviewers, separated by ',', to add in the PR"
	log "\t-s, --script\t The path to a shell script to execute after the dependency is updated. It will receive the extVariable name, the current version and the new version number as params."
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
		-s|-script|--script) script="$2" ;;
	esac
	shift
	shift
done

if [ -z "$json" ] || [ -z "$gradleDependenciesPath" ]; then
	log "You are missing one of the require params.\n"
	help
fi

if [ -z "$branch" ]; then
	branch="$DEFAULT_BRANCH"
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

log "Fetching '$branch' branch."
git fetch "$REMOTE" "$branch"

transformedDependencies=()
transformedVersions=()
transformedChangelogs=()

for row in $(echo "$json" | jq -r '.[] | @base64'); do
	_jq() {
		echo ${row} | base64 --decode | jq -r ${1}
	}

	group=$(_jq '.group')
	name=$(_jq '.name')
	currentVersion=$(_jq '.currentVersion')
	availableVersion=$(_jq '.availableVersion')
	changelog=$(_jq '.changelog')

	extVersionVariable="$(findVersionsVariableName "$group" "$name" "$gradleDependenciesPath")"

	log "\nProcessing $group:$name..."

	if [[ "$extVersionVariable" != "-1" ]]; then
		# If the update already exists. We will check the amount of differences between the source branch and the updated branch.
		# If the source branch has received an update, we will delete the updated branch and process it again to get the latest changes.
		if [[ "$(isAlreadyProcessed "$extVersionVariable" "$availableVersion")" == "1" ]]; then
			remoteBranch="$(id "$extVersionVariable" "$availableVersion")"

			if [[ "$(differencesBetween "$branch" "$remoteBranch")" != "0" ]]; then
				log "'$branch' has changed since the update to '$group:$name:$availableVersion'. Processing it again..."
				git branch -D "$remoteBranch"
			else
				log "PR is already open for '$group:$name:$availableVersion'."
				continue
			fi
		fi

		index=${#transformedDependencies[@]}
		changelogMd="- [${name}](${changelog})"

		for i in "${!transformedDependencies[@]}"; do
			if [[ "${transformedDependencies[$i]}" = "${extVersionVariable}" ]]; then
				index="${i}"
				changelogMd="${changelogMd}\n${transformedChangelogs[${i}]}"
			fi
		done

		transformedDependencies[$index]="${extVersionVariable}"
		transformedVersions[$index]="${currentVersion} ${availableVersion}"
		transformedChangelogs[$index]="${changelogMd}"
	else
		log "Couldnt find the extVersionVariable for '$group:$name'."
	fi
done

for i in "${!transformedDependencies[@]}"; do
	versions=(${transformedVersions[$i]})

	main "${transformedDependencies[$i]}" "${versions[0]}" "${versions[1]}" "${transformedChangelogs[$i]}" "$gradleDependenciesPath" "$branch" "$workspace" "$repo" "$user" "$password" "$reviewers" "$script"

	log "\nSleeping for $SLEEP_DURATION second(s) before continuing..."
	sleep $SLEEP_DURATION
done