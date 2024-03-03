#!/usr/bin/env bash
#
# Created by André Carvalho on 10th September 2021
# Last modified: 3rd March 2024
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
readonly VERSION="2.1.2"

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
	local toml="${11}"

	log "\nResetting back to '$mainBranch' branch..."
	git reset "$file" > /dev/null
	git checkout --force "${mainBranch}" || {
		log "${RED}Couldn't fetch '$mainBranch'. Please check if '$mainBranch' exists.${RESET}"
		exit 1
	}

	prepareBranch "$id" "$mainBranch" "$updateMechanism"
	updateDependenciesFile "$id" "$declaration" "$fromVersion" "$toVersion" "$file" "$toml"
	publish "$id" "$fromVersion" "$toVersion" "$file" "$mainBranch" "$affectedLibraries" "$releaseNotes" "$callback" "$updateMechanism"

	if [[ "$updateMechanism" == "$REBASE" ]]; then
		local command="$(git rev-parse --verify REBASE_HEAD)"

		if [[ "$?" != "128" ]]; then
			git rebase --abort &> /dev/null
		fi

		log "\nRebase completed!"
	fi
}

function isVersionUpdateAlreadyProcessed() {
	local branch="$(id "$1")"
	local command="$(git ls-remote --exit-code --heads "$REMOTE" "$branch")"

	local hasError="$?"

	if [[ "$hasError" != "0" ]] || [[ -z "$command" ]]; then
		echo "false"
	else
		# The git command didn't return an error which means the branch already exists on the remote
		echo "true"
	fi
}

function prepareBranch() {
	local branch="$(id "$1")"
	local baseBranch="$2"
	local updateMechanism="$3"

	log "\nPreparing working branch ($branch)..."

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
	local toml="$6"

	if [[ "$toml" == "true" ]]; then
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
			log "${RED}Couldn't find the original version declaration. Please check if you declared with a space after the ':'. eg: KEY : VALUE${RESET}"
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
	local toml="$4"

	if [[ "$toml" == "true" ]]; then
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
			log "\nNothing to push. Skipping it..."
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

	if [[ "$diff" != "0" ]]; then
		echo "true"
	else
		echo "false"
	fi
}

function hasOpenedBranchBeenUpdated() {
	local metadata="$(differences "$1" "$2")"
	local diff=( $metadata )

	if [[ "$((diff[1]))" -ge 2 ]]; then
		echo "true"
	else
		echo "false"
	fi
}

function booleanInput() {
	local param="$1"

	if [[ "$param" == [tT] || "$param" == [tT][rR][uU][eE] || "$param" == "1" ]]; then
		echo "true"
	else
		echo "false"
	fi
}

function help() {
	log "${BOLD}Gradle Dependencies Updater ($VERSION) developed by André Carvalho${RESET}\n"
	log "Usage: $0 -j \"{ ... }\" -d \"path(s) to the file(s) where the dependencies are declared\" -v \"path to the file where the dependencies versions are declared\""
	log "    -j, --json        \t The dependencies json content."
	log "    -d, --dependencies\t The path(s) to the file(s) where the dependencies are declared, separated by comma ','."
	log "    -v, --versions    \t The path to the file where the dependency versions are declared."
	log "    -b, --branch      \t The name of the main git branch."
	log "    -i, --ignore      \t All the dependencies ids that should be ignored, separated by comma ','."
	log "    -r, --rebase      \t Wether or not to rebase an already processed dependencies updates."
	log "    -c, --callback    \t The path to a shell script that gets called when an update to a dependency is made. It gets all the params as key values pairs.\n"
	exit 1
}

clear

if ! [[ -x "$(command -v jq)" ]]; then
	log "${RED}\"jq\" couldn't be found. Please be sure it's installed and included in your PATH environment variable!\n${RESET}"
	exit 1
fi

while [ $# -gt 0 ]; do
	case "$1" in
		-j|-json|--json) json="$2" ;;
		-d|-dependencies|--dependencies) IFS=',' read -r -a dependenciesPath <<< "$2" ;;
		-v|-versions|--versions) versionsPath="$2" ;;
		-b|-branch|--branch) branch="$2" ;;
		-i|-ignore|--ignore) IFS=',' read -r -a ignoreItems <<< "$2" ;;
		-r|-rebase|--rebase) reprocess="$(booleanInput "$2")" ;;
		-c|-callback|--callback) callback="$2" ;;
	esac
	shift
	shift
done

remoteVersion="$(curl --silent https://api.github.com/repos/Andr3Carvalh0/Gradle_Dependencies_Updater/tags | jq -r '.[0].name')"

if [[ -n "$remoteVersion" && "$remoteVersion" != "$VERSION" ]]; then
	log "${BOLD}\n[i] A new version ($remoteVersion) is available!\n[i] You can download it at https://github.com/Andr3Carvalh0/Gradle_Dependencies_Updater${RESET}\n"
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
shortIds=()
toml=$([ "$dependenciesPath" == *".toml"* ] && echo "true" || echo "false")

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
		versionVariable="$(findVersionsVariableName "$group" "$name" "${dependenciesPath[${i}]}" "$toml")"

		if [[ "$versionVariable" != "-1" ]]; then
			processingVersionVariable="$versionVariable"
			break
		fi
	done

	log "\nProcessing $group:$name..."

	if [[ "$processingVersionVariable" != "-1" ]]; then
		shortId=$([ "$toml" == "true" ] && echo "$(echo "$processingVersionVariable" | awk -F " " '{ print $1 }')" || echo "$processingVersionVariable")
		mechanism="$NONE"

		# If the update already exists. We will check the amount of differences between the source branch and the updated branch.
		# If the source branch has received an update, we will delete the updated branch and process it again to get the latest changes.
		if [[ "$(isVersionUpdateAlreadyProcessed "$shortId")" == "true" ]]; then
			if [[ "$reprocess" == "false" ]]; then
				log "'$group:$name:$availableVersion' was processed before and rebasing is disabled. Skipping it..."
				continue
			fi

			remoteBranch="$(id "$shortId")"

			if [[ "$(hasBaseBranchBeenUpdated "$branch" "$remoteBranch")" == "true" ]]; then
				log "'$branch' has changed since the update to '$group:$name:$availableVersion'"

				if [[ "$(hasOpenedBranchBeenUpdated "$branch" "$remoteBranch")" == "true" ]]; then
					log "Previous version of the update branch has more work than just the version bump. Trying to rebase it..."
					mechanism="$REBASE"
				else
					log "Previous version of the update branch hasnt changed, destroying it and processing the dependency update again..."

					git branch -D "$remoteBranch" || {
						log "[i] Failed to delete '$remoteBranch' locally, probably because it doesnt exist. Continuing..."
					}
					mechanism="$DESTRUCTIVE"
				fi
			else
				log "An updated branch for '$group:$name:$availableVersion' is already available! Skipping it..."
				continue
			fi
		fi

		index=${#transformedDependencies[@]}
		affectedLibraries="${group}:${name}"
		releaseNotes="$changelog"

		for i in "${!transformedDependencies[@]}"; do
			if [[ "${transformedDependencies[$i]}" = "$processingVersionVariable" ]]; then
				index="${i}"
				affectedLibraries="${affectedLibraries},${transformedAffectedLibraries[${i}]}"
				releaseNotes="${releaseNotes},${transformedReleaseNotes[${i}]}"
			fi
		done

		shortIds[$index]="$shortId"
		updateMechanism[$index]="$mechanism"
		transformedDependencies[$index]="$processingVersionVariable"
		transformedVersions[$index]="$currentVersion $availableVersion"
		transformedReleaseNotes[$index]="$releaseNotes"
		transformedAffectedLibraries[$index]="$affectedLibraries"
	else
		log "${RED}Couldn't find the version variable for '$group:$name' ${RESET}"
	fi
done

for i in "${!transformedDependencies[@]}"; do
	versions=(${transformedVersions[$i]})
	uniqueId="${transformedDependencies[$i]}"
	shortId="${shortIds[$i]}"

	if [[ -n "$uniqueId" ]]; then
		if [[ "$(contains ignoreItems "$shortId")" == "false" ]]; then
			main "$shortId" "$uniqueId" "${versions[0]}" "${versions[1]}" "${transformedReleaseNotes[$i]}" "${transformedAffectedLibraries[$i]}" "$versionsPath" "$branch" "$callback" "${updateMechanism[$i]}" "$toml"
		else
			log "$shortId is in ignore list. Skipping it..."
		fi
	else
		log "${RED}Got invalid variable id for: ${transformedAffectedLibraries[$i]}${RESET}"
	fi
done
