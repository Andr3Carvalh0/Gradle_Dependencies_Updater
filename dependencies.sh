#!/usr/bin/env bash
#
# Created by André Carvalho on 10th September 2021
# Last modified: 19th February 2024
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

readonly NONE="0"
readonly REBASE="1"
readonly DESTRUCTIVE="2"

function main() {
	local extVersionVariable="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local releaseNotes="$4"
	local affectedLibraries="$5"
	local file="$6"
	local mainBranch="$7"
	local callback="$8"
	local updateMechanism="$9"

	log "\nResetting back to '$mainBranch' branch..."
	git checkout --force "${mainBranch}" || {
		log "Couldnt fetch '$mainBranch'. Please check if '$mainBranch' exists."
		exit 1
	}

	prepareBranch "$extVersionVariable" "$mainBranch" "$updateMechanism"
	updateDependenciesFile "$extVersionVariable" "$fromVersion" "$toVersion" "$file"
	publish "$extVersionVariable" "$fromVersion" "$toVersion" "$file" "$mainBranch" "$affectedLibraries" "$releaseNotes" "$callback" "$updateMechanism"

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
	local extVersionVariable="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local file="$4"

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
	local originalVersion="$(findInFile "$extVersionVariable " "$file")"

	if [ -z "$originalVersion" ]; then
		log "Couldnt find the original version declaration. Please check if you declared with a space after the ':'. eg: KEY : VALUE"
	else
		local versionInFile="$(echo "$originalVersion" | awk '{print $NF}')"
		local versionInFileTransformed="$(echo "${versionInFile//\"}")"

		local newVersion=$(echo "$originalVersion" | sed "s/${versionInFileTransformed}/${toVersion}/g")

		log "Saving $file file..."
		echo "$(echo "$(cat "$file")" | sed "s/${originalVersion}/${newVersion}/g")" > "$file"
	fi
}

function findVersionsVariableName() {
	local group="$1"
	local name="$2"
	local file="$3"
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

function help() {
	log "Usage: $0 -j json -g dependecies file path"
	log "\t-j, --json\t The dependencies json content."
	log "\t-d, --dependencies\t The path(s) to the file(s) where the dependencies are declared, separated by comma ','."
	log "\t-v, --versions\t The path to the file where the dependency versions are declared."
	log "\t-b, --branch\t The name of the main git branch."
	log "\t-c, --callback\t The path to a shell script that gets called when an update to a dependency is made.\n\t\t\t It gets all the params as key values pairs."
	log "\n\t\t\t eg: callback --variable \"MOSHI\" --fromVersion \"1.0.0\" --toVersion \"1.0.0\" --modules \"com.squareup.moshi:moshi-kotlin\" --releaseNotes \"https://github.com/square/moshi\" --sourceBranch \"develop\" --targetBranch \"housechores/moshi\""
	log "\t\t\t\t variable: The version variable name."
	log "\t\t\t\t fromVersion: The installed library version."
	log "\t\t\t\t toVersion: The updated library version."
	log "\t\t\t\t modules: All the affected modules that are affected by updating "\variable"\ separated by a comma (',')."
	log "\t\t\t\t releaseNotes: The url where you can find all that changed per module. Again values are separated by a comma (',')."
	log "\t\t\t\t sourceBranch: The base branch we used to process the new changes."
	log "\t\t\t\t targetBranch: The branch where all the version changes were applied to."
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		-j|-json|--json) json="$2" ;;
		-d|-dependencies|--dependencies) IFS=',' read -r -a dependenciesPath <<< "$2" ;;
		-v|-versions|--versions) versionsPath="$2" ;;
		-b|-branch|--branch) branch="$2" ;;
		-c|-callback|--callback) callback="$2" ;;
	esac
	shift
	shift
done

if [ -z "$json" ] || [ -z "$dependenciesPath" ] || [ -z "$versionsPath" ]; then
	log "You are missing one of the require parameters.\n"
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
		versionVariable="$(findVersionsVariableName "$group" "$name" "${dependenciesPath[${i}]}")"

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
				log "'$branch' has changed since the update to '$group:$name:$availableVersion'."

				if [[ "$(hasOpenedBranchBeenUpdated "$branch" "$remoteBranch")" == "1" ]]; then
					log "Previous version of the update PR has more work than just the version bump. Trying to rebase it..."
					mechanism="$REBASE"
				else
					log "Previous version of the update PR hasnt changed, destroying it and processing the dependency update again..."

					git branch -D "$remoteBranch" || {
						log "Failed to delete '$remoteBranch' locally, probably because it doesnt exist. Continuing..."
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
		log "Couldnt find the extVersionVariable for '$group:$name'."
	fi
done

for i in "${!transformedDependencies[@]}"; do
	item=(${transformedVersions[$i]})

	main "${transformedDependencies[$i]}" "${item[0]}" "${item[1]}" "${transformedReleaseNotes[$i]}" "${transformedAffectedLibraries[$i]}" "$versionsPath" "$branch" "$callback" "${updateMechanism[$i]}"
done

log "All done!"
