# Gradle Dependencies Updater

A shell script that helps you automatically create PRs in bitbucket for every dependecy update that your project might need.

### Usage

For the script to function you need to at least pass 2 parameters: `--json` were you pass the json with dependencies that need to be updated and `--gradleDependenciesPath` were you pass the path for the file where you declare your gradle dependencies.

eg: 
```
sh ./dependencies.sh --json "`cat ./examples/data_with_duplicated.json`" --gradleDependenciesPath "./gradle/dependencies.gradle"
```
