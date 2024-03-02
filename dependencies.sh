#!/usr/bin/env bash
#
# Created by André Carvalho on 10th September 2021
# Last modified: 2nd March 2024
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
# And creates a new branch where the dependency is updated.
#
readonly BRANCH_PREFIX="housechores"
readonly REMOTE="origin"
readonly DEFAULT_BRANCH="develop"
readonly VERSION="2.1.0"

readonly BOLD='\033[1m'
readonly RED='\033[0;31m'
readonly RESET='\033[0m'

readonly NONE="0"
readonly REBASE="1"
readonly DESTRUCTIVE="2"

function main() {
	local id="$1"
	local declaration="$2"
	local fromVersion="$3"
	local toVersion="$4"
	local releaseNotes="$5"
	local affectedLibraries="$6"
	local file="$7"
	local mainBranch="$8"
	local callback="$9"
	local updateMechanism="${10}"
	local isToml="${11}"

	log "\nResetting back to '$mainBranch' branch..."
	git reset "$file" > /dev/null
	git checkout --force "${mainBranch}" || {
		log "Couldnt fetch '$mainBranch'. Please check if '$mainBranch' exists."
		exit 1
	}

	prepareBranch "$id" "$mainBranch" "$updateMechanism"
	updateDependenciesFile "$id" "$declaration" "$fromVersion" "$toVersion" "$file" "$isToml"
	publish "$id" "$fromVersion" "$toVersion" "$file" "$mainBranch" "$affectedLibraries" "$releaseNotes" "$callback" "$updateMechanism"

	if [[ "$updateMechanism" == "$REBASE" ]]; then
		local command="$(git rev-parse --verify REBASE_HEAD)"

		if [[ "$?" != "128" ]]; then
			git rebase --abort
		fi
	fi
}

function isVersionUpdateAlreadyProcessed() {
	local branch="$(id "$1")"
	local command="$(git ls-remote --exit-code --heads "$REMOTE" "$branch")"

	local hasError="$?"

	if [[ "$hasError" != "0" ]] || [[ -z "$command" ]]; then
		echo "0"
	else
		# The git command didn't return an error which means the branch already exists on the remote
		echo "1"
	fi
}

function prepareBranch() {
	local branch="$(id "$1")"
	local baseBranch="$2"
	local updateMechanism="$3"

	log "\nPreparing working branch..."

	if [[ "$updateMechanism" == "$REBASE" ]]; then
		git checkout --force "$branch"
		git rebase "$baseBranch"
	else
		git checkout -b "$branch"
	fi
}

function updateDependenciesFile() {
	local id="$1"
	local substring="$2"
	local fromVersion="$3"
	local toVersion="$4"
	local file="$5"
	local isToml="$6"

	if [[ "$isToml" == "true" ]]; then
		log "\nUpdating '$id' from '$fromVersion' to '$toVersion'"
		local transformedText=${substring/$fromVersion/$toVersion}

		log "Saving $file file..."
		echo "$(echo "$(cat "$file")" | sed "s/${substring}/${transformedText}/g")" > "$file"
	else
		log "\nUpdating '$substring' from '$fromVersion' to '$toVersion'"
		# The space at the end of "$substring " is important here.
		# It prevents false positives when we have something like:
		#
		# ...
		# composeNavigation      : '2.4.0-alpha06',
		# compose                : '1.0.1',
		# ...
		#
		# And we are updating the compose version, and not the composeNavigation, for example
		local originalVersion="$(findInFile "$substring " "$file")"

		if [ -z "$originalVersion" ]; then
			log "${RED}Couldnt find the original version declaration. Please check if you declared with a space after the ':'. eg: KEY : VALUE${RESET}"
		else
			local versionInFile="$(echo "$originalVersion" | awk '{print $NF}')"
			local versionInFileTransformed="$(echo "${versionInFile//\"}")"

			local newVersion=$(echo "$originalVersion" | sed "s/${versionInFileTransformed}/${toVersion}/g")

			log "Saving $file file..."
			echo "$(echo "$(cat "$file")" | sed "s/${originalVersion}/${newVersion}/g")" > "$file"
		fi

	fi
}

function findVersionsVariableName() {
	local group="$1"
	local name="$2"
	local file="$3"
	local isToml="$4"

	if [[ "$isToml" == "true" ]]; then
		local dependency="$(findInFile "module = \"$group:$name\"" "$file")"

		if [ -n "$dependency" ]; then
			if [[ "$dependency" == *"version.ref = "* ]]; then
				local extVariable="$(substring "version.ref = \"" "\" }" "$dependency")"
				echo "$(findInFile "$extVariable = \"" "$file")"
			else
				echo "$dependency"
			fi
		else
			echo "-1"
		fi
	else
		local dependency="$(findInFile "$group:$name:" "$file")"

		if [ -n "$dependency" ]; then
			# Handle normal dependencies
			local versionVariable="$(substring "." "" "$(substring "{" "}" "$dependency")")"

			if [ -n "$versionVariable" ]; then
				echo "$versionVariable"
			else
				echo "-1"
			fi
		else
			# Handle Gradle Plugins versions
			dependency="$(findInFile "$group" "$file")"

			if [[ -n "$dependency" ]]; then
				versionVariable="$(substring "." "" "$(substring "version" "" "$dependency")")"
				local versions=($versionVariable)

				if [ -n "${versions[0]}" ]; then
					echo "${versions[0]}"
				else
					echo "-1"
				fi
			else
				echo "-1"
			fi
		fi
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
		echo $(echo "$text" | awk -F "$fromChar" '{ print $2 }')
	else
		echo "$(sed "s/.*${fromChar}\(.*\)${untilChar}.*/\1/" <<< "$text")"
	fi
}

function contains() {
	local array="$1[@]"
	local item=$2
	local hasMatch="false"

	for element in "${!array}"; do
		if [[ $element == "$item" ]]; then
			hasMatch="true"
			break
		fi
	done

	echo "$hasMatch"
}

function log() {
	printf "$1\n"
}

function publish() {
	local name="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local file="$4"
	local mainBranch="$5"
	local affectedLibraries="$6"
	local releaseNotes="$7"
	local callback="$8"
	local updateMechanism="$9"
	local branch="$(id "$name")"

	log "\nCommitting changes..."
	git add "$file"

	if [[ `git status --porcelain` ]]; then
		git commit -m "Update $name to version $toVersion"

		log "\nPushing changes to remote..."
		git push --force "$REMOTE" "$branch"

		"$callback" --variable "$name" --fromVersion "$fromVersion" \
			--toVersion "$toVersion" --modules "$affectedLibraries" \
			--releaseNotes "$releaseNotes" --sourceBranch "$branch" --targetBranch "$mainBranch"
	else
		if [[ "$updateMechanism" == "$REBASE" ]]; then
			log "\nPushing changes to remote..."
			git push --force "$REMOTE" "$branch"
		else
			log "\nNothing to push. Skipping..."
		fi
	fi
}

function id() {
	local input="$1"
	local lowercased="$(echo "$(echo "$input" | awk '{print tolower($0)}')")"

	echo "$BRANCH_PREFIX/$lowercased"
}

function differences() {
	local fromBranch="$1"
	local toBranch="$2"

	git fetch "$REMOTE" "$toBranch"

	# Returns the amount of changes that both branches had since their split
	# Eg: Imagining that fromBranch is release and toBranch develop after both being created the output would be 0 0
	# If I create a commit in develop it becomes 0 1, and if I later commit in release it becomes 1 1
	echo "$(git rev-list --left-right --count "$REMOTE/$fromBranch"..."$REMOTE/$toBranch")"
}

function hasBaseBranchBeenUpdated() {
	local metadata="$(differences "$1" "$2")"
	local diff=( $metadata )

	echo "${diff}"
}

function hasOpenedBranchBeenUpdated() {
	local metadata="$(differences "$1" "$2")"
	local diff=( $metadata )

    if [[ "$((diff[1]))" -ge 2 ]]; then
        echo "1"
    else
        echo "0"
    fi
}

function postScript() {
	exit 0
}

trap postScript SIGHUP SIGINT SIGQUIT SIGABRT EXIT

function help() {
	log "${BOLD}Gradle Dependencies Updater ($VERSION) ${RESET}\n"
	log "Usage: $0 -j \"{ ... }\" -d \"path to the file where dependencies are declared\" -v \"path to the file where dependencies versions are declared\""
	log "    -j, --json        \t The dependencies json content."
	log "    -d, --dependencies\t The path(s) to the file(s) where the dependencies are declared, separated by comma ','."
	log "    -v, --versions    \t The path to the file where the dependency versions are declared."
	log "    -b, --branch      \t The name of the main git branch."
	log "    -i, --ignore      \t All the dependencies ids that should be ignored, separated by comma ','."
	log "    -t, --is_toml     \t Wether or not we are going to process a .toml file."
	log "    -c, --callback    \t The path to a shell script that gets called when an update to a dependency is made. It gets all the params as key values pairs.\n"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		-j|-json|--json) json="$2" ;;
		-d|-dependencies|--dependencies) IFS=',' read -r -a dependenciesPath <<< "$2" ;;
		-v|-versions|--versions) versionsPath="$2" ;;
		-b|-branch|--branch) branch="$2" ;;
		-i|-ignore|--ignore) IFS=',' read -r -a ignoreItems <<< "$2" ;;
		-c|-callback|--callback) callback="$2" ;;
		-t|-is_toml|--is_toml) isToml="$2" ;;
	esac
	shift
	shift
done

remoteVersion="$(curl --silent https://api.github.com/repos/Andr3Carvalh0/Gradle_Dependencies_Updater/tags | jq -r '.[0].name')"

clear

if [[ -n "$remoteVersion" && "$remoteVersion" != "$VERSION" ]]; then
    log "${BOLD}\n[i] A new version ($remoteVersion) is available!\n${RESET}"
fi

if [ -z "$json" ] || [ -z "$dependenciesPath" ] || [ -z "$versionsPath" ]; then
	log "${RED}You are missing one of the require parameters.\n${RESET}"
	help
fi

if [ -z "$branch" ]; then
	branch="$DEFAULT_BRANCH"
fi

log "Fetching '$branch' branch."
git fetch "$REMOTE" "$branch"

transformedDependencies=()
transformedVersions=()
transformedAffectedLibraries=()
transformedReleaseNotes=()
updateMechanism=()

for row in $(echo "$json" | jq -r '.[] | @base64'); do
	_jq() {
		echo "${row}" | base64 --decode | jq -r "${1}"
	}

	group=$(_jq '.group')
	name=$(_jq '.name')
	currentVersion=$(_jq '.currentVersion')
	availableVersion=$(_jq '.availableVersion')
	changelog=$(_jq '.changelog')

	for i in "${!dependenciesPath[@]}"; do
		versionVariable="$(findVersionsVariableName "$group" "$name" "${dependenciesPath[${i}]}" "$isToml")"

		if [[ "$versionVariable" != "-1" ]]; then
			extVersionVariable="$versionVariable"
			break
		fi
	done

	log "\nProcessing $group:$name..."

	if [[ "$extVersionVariable" != "-1" ]]; then
		mechanism="$NONE"

		# If the update already exists. We will check the amount of differences between the source branch and the updated branch.
		# If the source branch has received an update, we will delete the updated branch and process it again to get the latest changes.
		if [[ "$(isVersionUpdateAlreadyProcessed "$extVersionVariable")" == "1" ]]; then
			remoteBranch="$(id "$extVersionVariable")"

			if [[ "$(hasBaseBranchBeenUpdated "$branch" "$remoteBranch")" != "0" ]]; then
				log "'$branch' has changed since the update to '$group:$name:$availableVersion'"

				if [[ "$(hasOpenedBranchBeenUpdated "$branch" "$remoteBranch")" == "1" ]]; then
					log "Previous version of the update PR has more work than just the version bump. Trying to rebase it..."
					mechanism="$REBASE"
				else
					log "Previous version of the update PR hasnt changed, destroying it and processing the dependency update again..."

					git branch -D "$remoteBranch" || {
						log "${RED}Failed to delete '$remoteBranch' locally, probably because it doesnt exist. Continuing...${RESET}"
					}
					mechanism="$DESTRUCTIVE"
				fi
			else
				log "PR is already open for '$group:$name:$availableVersion'."
				continue
			fi
		fi

		index=${#transformedDependencies[@]}
		affectedLibraries="${group}:${name}"
    	releaseNotes="$changelog"

		for i in "${!transformedDependencies[@]}"; do
			if [[ "${transformedDependencies[$i]}" = "${extVersionVariable}" ]]; then
				index="${i}"
				affectedLibraries="${affectedLibraries},${transformedAffectedLibraries[${i}]}"
				releaseNotes="${releaseNotes},${transformedReleaseNotes[${i}]}"
			fi
		done

		updateMechanism[$index]="$mechanism"
		transformedDependencies[$index]="$extVersionVariable"
		transformedVersions[$index]="$currentVersion $availableVersion"
		transformedReleaseNotes[$index]="$releaseNotes"
		transformedAffectedLibraries[$index]="$affectedLibraries"
	else
		log "${RED}Couldnt find the extVersionVariable for '$group:$name' ${RESET}"
	fi
done

for i in "${!transformedDependencies[@]}"; do
	versions=(${transformedVersions[$i]})
	uniqueId="${transformedDependencies[$i]}"
	shortId=$([ "$isToml" == "true" ] && echo "$(echo "$uniqueId" | awk -F " " '{ print $1 }')" || echo "$uniqueId")

	if [[ -n "$uniqueId" ]]; then
		if [[ "$(contains ignoreItems "$shortId")" == "false" ]]; then
			main "$shortId" "$uniqueId" "${versions[0]}" "${versions[1]}" "${transformedReleaseNotes[$i]}" "${transformedAffectedLibraries[$i]}" "$versionsPath" "$branch" "$callback" "${updateMechanism[$i]}" "$isToml"
		else
			log "$shortId is in ignore list. Skipping it..."
		fi
	else
		log "${RED}Got invalid variable id for: ${transformedAffectedLibraries[$i]}${RESET}"
	fi
done
