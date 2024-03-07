#!/usr/bin/env bash
#
# Created by André Carvalho on 19th February 2024
# Last modified: 7th March 2024
#
# Creates a pull request in Bitbucket.
#
readonly BITBUCKET_HOST="api.bitbucket.org/2.0"

function getReviewers() {
	local param="$1"
	local accounts="uuid"
	
	IFS=',' read -r -a reviewersArray <<< "$accounts"

	prReviewers="\"reviewers\": ["

	for index in "${!reviewersArray[@]}"
	do
		prReviewers="$prReviewers{ \"uuid\": \"{${reviewersArray[index]}}\" },"
	done

	prReviewers="${prReviewers::${#prReviewers}-1}"
	prReviewers="$prReviewers]"

	echo "$prReviewers"
}

function getUpdatedLibraries() {
	local modules="$1"

	IFS=',' read -r -a modulesArray <<< "$modules"

	local result=""

	for i in "${!modulesArray[@]}"; do
		result="$result- ${modulesArray[${i}]} \n"
	done

	echo "$result"
}

function getChangelogs() {
	local modules="$1"
	local releaseNotes="$2"

	IFS=',' read -r -a modulesArray <<< "$modules"
	IFS=',' read -r -a notesArray <<< "$releaseNotes"

	local result=""

	for i in "${!modulesArray[@]}"; do
		IFS=':' read -ra parts <<< "${modulesArray[${i}]}"
		local id=$([ "${#parts[@]}" == "1" ] && echo "${modulesArray[${i}]}" || echo "${parts[1]}")
		
		if [[ "$result" != *"${notesArray[${i}]}"* ]]; then
			result="$result- [Changelog for $id](${notesArray[${i}]}){: data-inline-card='' } \n"
		fi
	done

	echo "$result"
}

function main() {
	local variable="$1"
	local fromVersion="$2"
	local toVersion="$3"
	local modules="$4"
	local releaseNotes="$5"
	local sourceBranch="$6"
	local targetBranch="$7"

	local openedPrs="$(curl "https://$BITBUCKET_HOST/repositories/$WORKSPACE/$REPO/pullrequests?pagelen=50" --request "GET" --header "Content-Type: application/json" --header "Authorization: Bearer $BITBUCKET_TOKEN")"
	local dependencyPr="$(echo "$openedPrs" | jq '.values' | jq -r --arg title "Update $variable from" -c '.[] | select(.title | contains($title))')"

	local prTitle="Update $variable from version $fromVersion to version $toVersion"
	local prDescription="This PR updates **$variable** from version **$fromVersion** to **$toVersion**. \n\n### **🔗 Updated libraries:**\n\n$(getUpdatedLibraries "$modules") \n\n### **🌍 Changelogs:**\n\n$(getChangelogs "$modules" "$releaseNotes")\n---\n\n🤖 This PR was created by the [Gradle Dependencies Updater](https://github.com/Andr3Carvalh0/Gradle_Dependencies_Updater) script.\n‌"

	if [[ -z "$dependencyPr" ]]; then
		echo -e "\nOpening a new Pull Request..."

		curl "https://$BITBUCKET_HOST/repositories/$WORKSPACE/$REPO/pullrequests" \
			--request "POST" \
			--header "Content-Type: application/json" \
			--header "Authorization: Bearer $BITBUCKET_TOKEN" \
			--data "{
					\"title\": \"$prTitle\",
					\"description\": \"$prDescription\",
					\"source\": {
						\"branch\": {
							\"name\": \"$sourceBranch\"
						}
					},
					$(getReviewers "$modules"),
					\"destination\": {
						\"branch\": {
							\"name\": \"$targetBranch\"
						}
					},
					\"close_source_branch\": true
				}"
	else
		echo -e "\nA Pull Request is already opened. Updating the metadata to indicate we are updating to version \"$toVersion\"..."
		local prTitle="$(echo "$dependencyPr" | jq '.title')"

		if [[ "$prTitle" == *"$toVersion"* ]]; then
			echo -e "\nThere is nothing to update in the Pull Request since it already mentions the latest versions, skipping it..."
		else
			local prId="$(echo "$dependencyPr" | jq '.id')"
			echo -e "\nUpdating Pull Request ($prId) title to mention the new version...."
			curl "https://$BITBUCKET_HOST/repositories/$WORKSPACE/$REPO/pullrequests/$prId" \
				--request "PUT" \
				--header "Content-Type: application/json" \
				--header "Authorization: Bearer $BITBUCKET_TOKEN" \
				--data "{
					\"title\": \"$prTitle\",
					\"description\": \"$prDescription\"
				}"
		fi
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		-variable|--variable) variable="$2" ;;
		-fromVersion|--fromVersion) fromVersion="$2" ;;
		-toVersion|--toVersion) toVersion="$2" ;;
		-modules|--modules) modules="$2" ;;
		-releaseNotes|--releaseNotes) releaseNotes="$2" ;;
		-sourceBranch|--sourceBranch) sourceBranch="$2" ;;
		-targetBranch|--targetBranch) targetBranch="$2" ;;
	esac
	shift
	shift
done

main "$variable" "$fromVersion" "$toVersion" "$modules" "$releaseNotes" "$sourceBranch" "$targetBranch"
