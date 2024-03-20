# Gradle Dependencies Updater

A shell script that automates your Gradle project dependencies updates.

## How it all started

The idea of this project was to have something similar to [Github's Dependabot](https://github.com/dependabot), but make it not only compatible with Bitbucket (Dependabot had that goal before it was purchased by Microsoft/Github), but also with the way we declare our dependencies in the Android project.

In this document, I will (try to) go over the details of the implementation and go over some of the decisions that were taken.

But first, a bit of backstory... 😄

## A long time ago in a galaxy far, far way...?

The way we declare our dependencies in the project is to have a single file (dependencies.gradle) containing all the dependencies (we have multiple modules, so having a single source of truth makes it easier to use the same version of those libraries, in the different modules) with the following format:

```
ext {
    versions = [
        coil : "1.3.2",
		(...)
	]

 	dependencies = [
        coil : "io.coil-kt:coil:${versions.coil}",
		(...)
	]
}
```

As you can imagine, if you wanted to update any library, all you need to do is:

1. Figure out if there is a new version.
2. Open the dependencies file, find the library's unique artifact id. An artifact's id is composed of the library's group name + ":" + the library's name. For example, for the coil library(for the non-android devs. Coil is the image loading library we use to fetch all the images that aren't shipped with the libraries) the artifact's id would be **io.coil-kt:coil** (as you can see in the snippet).
3. After finding the library artifact's id, check which version variable we are using to store the version value, and replace that.
4. Check if everything is ok, commit the changes and create a PR.
5. Profit?

But this is tedious work and we are geeks, we can do better, so let's automate it!  😄

## How can we figure out when there is an update available?

The 1st thing we need to figure out is how to detect if there is an update available. To do that there are 2 options available:

1. Parse the **dependencies.gradle** file, find out which dependencies we use and their unique artifact id, and query all the possible repositories to find out the latest version. (note: this is the approach Github's Dependabot chose)
2. Use the built-in Gradle tasks, and let Gradle be the one responsible for figuring everything out.

We went for solution **#2** because:

- We are already checking out the entire project anyhow, so we have access to everything, and can run the Gradle task without any problems.
- No need to write API calls to all the repositories we use, to check for updates. It's also easy to track new repositories since Gradle will already have everything in place.
- In case we change how we track the libraries we use, that will require no changes on this step because Gradle will already track all of it.

With that all the way to detect all the dependencies + their updates we could run the following task:

```
./gradlew :app:dependencies
```

and you would get the following output:

```
(...)

releaseCompileClasspath - Compile classpath for compilation 'release' (target  (androidJvm)).
+--- io.coil-kt:coil:1.3.2 -> 1.4.0 (*)
+--- app.cash.contour:contour:1.1.0
(...)
```

In this example, there is an update available for **coil** to version **1.4.0**.

## Parsing Gradle's dependencies report

We could parse the output of the previous Gradle command, but that's not the case.

We use [Ben Manes Gradle plugin](https://github.com/ben-manes/gradle-versions-plugin), which processes the previous output, and gives us all the information categorized with the following format:

```json
{
  "current": {
    "dependencies": [...],
    "count": 27
  },
  "outdated": {
    "dependencies": [...],
    "count": 27
  },
  "unresolved": {
    "dependencies": [...],
    "count": 27
  }
}
```

To access that data, lucky for us, Ben Manes' plugin allows us to provide a custom formatter, to do any data manipulation we might want (and we do it the check_dependencies.gradle )

With the **outdated** values, we will apply some minor filtering:

- Alpha, Beta & Release Candidate releases. If we are using a stable version we will discard any non-stable versions. If the current version is in alpha, beta, etc... This filtering will not be applied.

That filter is described as:

```groovy
def dependenciesBlacklist = [
    // Beta/RC/weird versions
    (String dependency, String currentVersion, String newVersion) -> {
        def stableKeywords = ['RELEASE', 'FINAL', 'GA']
        def versionRegex = /^[0-9,.v-]+(-r)?$/

        def isNewVersionStable = stableKeywords.any { it -> newVersion.toUpperCase().contains(it) } || (newVersion ==~ versionRegex)
        def isCurrentVersionStable = stableKeywords.any { it -> currentVersion.toUpperCase().contains(it) } || (currentVersion ==~ versionRegex)

        return !(isNewVersionStable || !isNewVersionStable && !isCurrentVersionStable)
    }
]
```

With the result of this 1st triage, we will format the dependencies to be represented with the following object type:

```groovy
class Dependency {
    String name               // the library name
    String group              // the library group
    String currentVersion     // the current version
    String availableVersion   // the new version
    String changelog          // the url that points to the latest version release notes. 
                              // this field is built based on the publisher url(comes from gradle) and the library group and library name.
}
```

And after that write all the values to a file (called **report.json**), like so:

```json
[
	{
		"group": "io.coil-kt",
		"name": "coil",
		"currentVersion": "1.3.2",
		"availableVersion": "1.4.0",
		"changelog": "https://github.com/coil-kt/coil/releases/tag/1.4.0"
	},
	{
		"group": "com.google.accompanist",
		"name": "accompanist-placeholder",
		"currentVersion": "0.18.0",
		"availableVersion": "0.19.0",
		"changelog": "https://github.com/google/accompanist/releases/tag/v0.19.0"
	}
]
```

## Processing the report.json

While we could have keep using the groovy/Gradle tasks to process the following steps, we instead, switch to using a bash script.

- For portability, and decoupling from the previous steps.
- It's easier to use git commands on a bash script vs Gradle task.

Now, with the previous JSON array, we will iterate every item, and update the version variable value, like previous mentioned. We do have some checks, but the script flow could be better described by the following flow state graph:

![Diagram](/assets/diagram_dark.png?#gh-dark-mode-only)
![Diagram](/assets/diagram_light.png?#gh-light-mode-only)

### A couple of things to note:

- To uniquely identify any version update, we use the version variable name (eg: **coil**) instead of the artifact's id (eg: **io.coil-kt:coil**). The reason for this is because different artifact's could be using the same version variable to track their version. Doing it this way we ensure we will only process/create a single PR for every version update.

- To uniquely identify, if we already processed that version variable update, we check for branches with the following structure: **dependabot/version.variable**. For example, with the **coil**, example from before we would check if a branch named **dependabot/coil** exists.

```
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
```

If an update branch is available we will compare it with the base branch, and determine if the update branch is behind the base branch.

In the case that it is, we will determine if there was more work done to the update branch, besides the version update...

- If there is, we will try to rebase the base branch into it, so we can keep all the changes. 
- Otherwise we will just delete the branch and reprocess it again, since thats easier.

```
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
```

### Examples

As you could have read this project is composed of 3 components: 

- 🤖 [If you wanna check all of those in action check the Android project.](./example/)
- 💻 If you wanna just check the dependabot component... You can use the jsons you find on the `data` folder, and pass them to the `update_dependencies.sh` script. Like so:

For the script to function you need to at least pass 3 parameters: 

- `--json` were you pass the json with dependencies that need to be updated
- `--dependencies` were you pass the path for the file where you declare your gradle dependencies.
- `--versions` were you pass the path for the file where you declare your gradle dependencies versions. It can be the same as `--dependencies`.

eg: 
```
./update_dependencies.sh --json "`cat ./data/data_with_duplicated.json`" \
	--dependencies "./gradle/dependencies.gradle" \
	--versions "./gradle/dependencies.gradle" 
```

## Goodies

I've also included a utilities folder, with some goodies in it 😄

- `ci.sh`: Script for the pipeline. It will generate the `report.json` with all the version updates, and then call the `update_dependencies.sh` script so all the update branches are created.
- `make_pull_request`: Script to create a PR in Bitbucket. You can use it on your own, or pass it to the `update_dependencies.sh`, like the `ci.sh` does.